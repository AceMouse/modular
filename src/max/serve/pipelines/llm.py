# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from __future__ import annotations

import asyncio
import logging
import os
import signal
from dataclasses import dataclass
from functools import partial
from typing import AsyncGenerator, Callable, Generic, Optional, TypeVar

import psutil
from max.pipelines.config import PipelineConfig
from max.pipelines.interfaces import PipelineTokenizer, TokenGeneratorRequest
from max.pipelines.kv_cache import KVCacheStrategy
from max.serve.scheduler.queues import (
    BatchingStrategy,
    BatchQueueConfig,
    EngineQueue,
)
from max.serve.telemetry.metrics import METRICS
from max.serve.telemetry.stopwatch import StopWatch, record_ms

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class TokenGeneratorOutput:
    decoded_token: str
    token_log_probabilities: Optional[list[float]] = None
    top_log_probabilities: Optional[list[dict[str, float]]] = None


@dataclass(frozen=True)
class TokenGeneratorPipelineConfig:
    """
    Example config

    .. code-block:: json

        {
            "context_encoding": {
                "strategy": "dynamic",
                "size": 1,
                "timeout": 0.1
            },
            "token_generation": {
                "strategy": "continuous",
                "size": 64,
                "timeout": 0.0
            }
        }
    """

    token_generation: BatchQueueConfig
    context_encoding: Optional[BatchQueueConfig] = None

    @classmethod
    def dynamic_homogenous(
        cls, batch_size: int, batch_timeout=0.1, max_forward_steps=1
    ) -> TokenGeneratorPipelineConfig:
        """The dynamic-homogenous config uses a single queue.
        Requests are dequeued into a batch and the entire batch is
        executed until all requests are completed.
        """
        token_generation_config = BatchQueueConfig(
            strategy=BatchingStrategy.DYNAMIC_IMMUTABLE,
            size=batch_size,
            timeout=batch_timeout,
            max_forward_steps=max_forward_steps,
        )
        config = cls(token_generation=token_generation_config)
        return config

    @classmethod
    def continuous_heterogenous(
        cls,
        tg_batch_size: int,
        ce_batch_size: int,
        ce_batch_timeout=0.1,
        max_forward_steps=1,
        target_ce_batch_tokens=4096,
    ) -> TokenGeneratorPipelineConfig:
        """The continuous-hetrogenous config creates 2 queues.
        Context-encoding is done via dynamic batching.
        Token-generation is done via continuous batching.
        """
        token_generation_config = BatchQueueConfig(
            strategy=BatchingStrategy.CONTINUOUS,
            size=tg_batch_size,
            timeout=0.0,
            max_forward_steps=max_forward_steps,
        )
        context_encoding_config = BatchQueueConfig(
            strategy=BatchingStrategy.DYNAMIC,
            size=ce_batch_size,
            timeout=ce_batch_timeout,
            target_sum_seq_len=target_ce_batch_tokens,
        )
        config = cls(
            context_encoding=context_encoding_config,
            token_generation=token_generation_config,
        )
        return config

    @classmethod
    def paged(
        cls,
        tg_batch_size: int,
        ce_batch_size: int,
        ce_batch_timeout: float = 0.1,
        max_forward_steps: int = 1,
        target_ce_batch_tokens: int = 4096,
    ) -> TokenGeneratorPipelineConfig:
        """The paged config creates 2 queues.
        Context-encoding is done via dynamic batching.
        Token-generation is done via continuous batching.

        This config is identical to the config returned by continuous_heterogenous.
        """
        return cls.continuous_heterogenous(
            tg_batch_size=tg_batch_size,
            ce_batch_size=ce_batch_size,
            ce_batch_timeout=ce_batch_timeout,
            max_forward_steps=max_forward_steps,
            target_ce_batch_tokens=target_ce_batch_tokens,
        )


@dataclass
class TokenGeneratorStats:
    token_gen_batch_size: int = 0
    token_gen_batch_calls: int = 0


TokenGeneratorContext = TypeVar("TokenGeneratorContext")


class TokenGeneratorPipeline(Generic[TokenGeneratorContext]):
    """Base class for LLM pipelines."""

    def __init__(
        self,
        model_name: str,
        tokenizer: PipelineTokenizer,
        engine_queue: EngineQueue,
    ):
        self.logger = logging.getLogger(self.__class__.__name__)
        self.logger.info("%s: Constructed", model_name)
        self.debug_logging = self.logger.isEnabledFor(logging.DEBUG)

        self.model_name = model_name
        self.tokenizer = tokenizer
        self.engine_queue = engine_queue
        self.stats = TokenGeneratorStats()

        self._background_tasks: set[asyncio.Task] = set()

    async def next_token(
        self, request: TokenGeneratorRequest
    ) -> AsyncGenerator[TokenGeneratorOutput, None]:
        """Generates and streams tokens for the provided request."""
        total_sw = StopWatch()
        self.logger.debug(
            "%s [%d]: Started: Elapsed: %0.2f ms",
            request.id,
            request.index,
            total_sw.elapsed_ms,
        )

        # Skip special tokens if tool use is enabled
        tool_use = request.tools is not None
        skip_special_tokens = tool_use

        try:
            with record_ms(METRICS.input_time):
                context = await self.tokenizer.new_context(request)
            # TODO(MAXCORE-137): TokenGeneratorContext currently does not enforce
            # a seq_len property.
            if hasattr(context, "seq_len"):
                METRICS.input_tokens(context.seq_len)

            with record_ms(METRICS.output_time):
                async for response in self.engine_queue.stream(
                    request.id, context
                ):
                    token_log_probabilities = None
                    top_log_probabilities = None
                    if log_prob := response.log_probabilities:
                        token_log_probabilities = (
                            log_prob.token_log_probabilities
                        )
                        top_log_probabilities = []
                        for top_log_probs in log_prob.top_log_probabilities:
                            decoded_log_probs = {}
                            for token_id, value in top_log_probs.items():
                                decoded_log_probs[
                                    await self.tokenizer.decode(
                                        context,
                                        token_id,
                                        skip_special_tokens=skip_special_tokens,
                                    )
                                ] = value
                            top_log_probabilities.append(decoded_log_probs)

                    yield TokenGeneratorOutput(
                        decoded_token=await self.tokenizer.decode(
                            context,
                            response.next_token,
                            skip_special_tokens=skip_special_tokens,
                        ),
                        token_log_probabilities=token_log_probabilities,
                        top_log_probabilities=top_log_probabilities,
                    )
        finally:
            if self.debug_logging:
                self.logger.debug(
                    "%s [%d]: Completed: Elapsed: %0.2f ms",
                    request.id,
                    request.index,
                    total_sw.elapsed_ms,
                )

    async def all_tokens(
        self, request: TokenGeneratorRequest
    ) -> list[TokenGeneratorOutput]:
        """Generates all tokens for the provided request."""
        return [token async for token in self.next_token(request)]

    async def __aenter__(self):
        self.logger.info("%s: Starting workers:", self.model_name)
        assert not self._background_tasks
        # TODO arekay - replace with better signalling
        if not psutil.pid_exists(self.engine_queue.pid):
            raise RuntimeError(
                f"Worker process {self.engine_queue.pid} not running"
            )

        # Add global fanout worker.
        self.create_background_task(self.engine_queue.response_worker)

        if not psutil.pid_exists(self.engine_queue.pid):
            raise RuntimeError(
                f"Worker process {self.engine_queue.pid} not running"
            )

        self.logger.info(
            "%s: Started workers: %d tasks",
            self.model_name,
            len(self._background_tasks),
        )
        return self

    async def __aexit__(self, exc_type, exc_value, traceback):
        self.logger.info("%s: Stopping workers", self.model_name)
        for task in self._background_tasks:
            task.cancel()
        # await asyncio.sleep(0.1)
        # TODO: also cancel any `queue.get()` tasks

    def create_background_task(self, fn: Callable):
        task_name = fn.__name__
        task = asyncio.create_task(fn())
        task.add_done_callback(partial(self.log_task_done, task_name=task_name))
        self._background_tasks.add(task)
        self.logger.info(
            "%s: Task Added: %s, %s, %d total",
            self.model_name,
            task_name,
            type(fn),
            len(self._background_tasks),
        )

    def log_task_done(self, task: asyncio.Task, task_name: str):
        # TODO - should gracefully shut down here.
        self._background_tasks.remove(task)
        self.logger.info(
            "%s: Task completed: %s, %d remaining",
            self.model_name,
            task_name,
            len(self._background_tasks),
        )
        # Cancel remaining tasks.
        for t in self._background_tasks:
            if not t.done():
                t.cancel("Terminating task")
        if task.cancelled():
            return
        e = task.exception()
        if e:
            self.logger.error("Task completed with error. Stopping", exc_info=e)
            # Shut server down.
            # Sending SIGTERM is ugly, but simplifies the internal plumbing.
            os.kill(os.getpid(), signal.SIGTERM)


def get_target_ce_batch_tokens(pipeline_config: PipelineConfig) -> int:
    if pipeline_config.target_num_new_tokens is not None:
        return pipeline_config.target_num_new_tokens

    # TODO(E2EOPT-23) temporary hard-coded default. We'll make this smarter later.
    return 4096


def batch_config_from_pipeline_config(
    pipeline_config: PipelineConfig, batch_timeout: float = 0.0
) -> TokenGeneratorPipelineConfig:
    target_ce_batch_tokens = get_target_ce_batch_tokens(pipeline_config)
    if pipeline_config.cache_strategy == KVCacheStrategy.CONTINUOUS:
        batch_config = TokenGeneratorPipelineConfig.continuous_heterogenous(
            tg_batch_size=pipeline_config.max_cache_batch_size,
            ce_batch_size=min(
                pipeline_config.max_cache_batch_size,
                pipeline_config.max_ce_batch_size,
            ),
            ce_batch_timeout=batch_timeout,
            max_forward_steps=pipeline_config.max_num_steps,
            target_ce_batch_tokens=target_ce_batch_tokens,
        )
    elif pipeline_config.cache_strategy == KVCacheStrategy.NAIVE:
        batch_config = TokenGeneratorPipelineConfig.dynamic_homogenous(
            batch_size=pipeline_config.max_cache_batch_size,
            batch_timeout=batch_timeout,
            max_forward_steps=pipeline_config.max_num_steps,
        )
    elif pipeline_config.cache_strategy == KVCacheStrategy.PAGED:
        batch_config = TokenGeneratorPipelineConfig.paged(
            tg_batch_size=pipeline_config.max_cache_batch_size,
            ce_batch_size=min(
                pipeline_config.max_cache_batch_size,
                pipeline_config.max_ce_batch_size,
            ),
            ce_batch_timeout=batch_timeout,
            max_forward_steps=pipeline_config.max_num_steps,
            target_ce_batch_tokens=target_ce_batch_tokens,
        )
    else:
        raise ValueError(
            f"{pipeline_config.cache_strategy} caching strategy is not"
            " supported by Serving."
        )

    logger.info(
        "Server configured with %s caching with batch size %s",
        pipeline_config.cache_strategy,
        pipeline_config.max_cache_batch_size,
    )

    return batch_config
