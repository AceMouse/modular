# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #


import logging
import os
from typing import Optional, Union

from max.serve.telemetry.common import logs_resource, otelBaseUrl
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from pythonjsonlogger import jsonlogger


def _getCloudProvider() -> str:
    providers = ["amazon", "google", "microsoft", "oracle"]
    path = "/sys/class/dmi/id/"
    if os.path.isdir(path):
        for idFile in os.listdir(path):
            try:
                with open(idFile, "r") as file:
                    contents = file.read().lower()
                    for provider in providers:
                        if provider in contents:
                            return provider
            except Exception:
                pass
    return ""


# Configure logging to console and OTEL.  This should be called before any
# 3rd party imports whose logging you wish to capture.
def configureLogging(
    console_level: Union[int, str],
    file_path: Optional[str] = None,
    file_level: Optional[Union[int, str]] = None,
    otlp_level: Optional[Union[int, str]] = None,
):
    logging_handlers: list[logging.Handler] = []

    # Create a console handler
    console_handler = logging.StreamHandler()
    console_formatter: logging.Formatter
    if os.getenv("MODULAR_STRUCTURED_LOGGING") == "1":
        console_formatter = jsonlogger.JsonFormatter()
    else:
        console_formatter = logging.Formatter(
            (
                "%(asctime)s.%(msecs)03d %(levelname)s: %(process)d %(threadName)s:"
                " %(name)s: %(message)s"
            ),
            datefmt="%H:%M:%S",
        )
    console_handler.setFormatter(console_formatter)
    console_handler.setLevel(console_level)
    logging_handlers.append(console_handler)

    if file_level is not None and file_path is not None:
        # Create a file handler
        file_handler = logging.FileHandler(file_path)
        file_formatter: logging.Formatter
        if os.getenv("MODULAR_STRUCTURED_LOGGING") == "1":
            file_formatter = jsonlogger.JsonFormatter()
        else:
            file_formatter = logging.Formatter(
                (
                    "%(asctime)s.%(msecs)03d %(levelname)s: %(process)d %(threadName)s:"
                    " %(name)s: %(message)s"
                ),
                datefmt="%y:%m:%d-%H:%M:%S",
            )
        file_handler.setFormatter(file_formatter)
        file_handler.setLevel(file_level)
        logging_handlers.append(file_handler)

    if otlp_level is not None:
        # Create an OTEL handler
        logger_provider = LoggerProvider(logs_resource)
        set_logger_provider(logger_provider)
        exporter = OTLPLogExporter(endpoint=otelBaseUrl + "/v1/logs")
        logger_provider.add_log_record_processor(
            BatchLogRecordProcessor(exporter)
        )
        otlp_handler = LoggingHandler(
            level=otlp_level, logger_provider=logger_provider
        )
        logging_handlers.append(otlp_handler)

    # Configure root logger level
    logger_level = min(h.level for h in logging_handlers)
    logger = logging.getLogger()
    logger.setLevel(logger_level)
    for handler in logging_handlers:
        logger.addHandler(handler)

    # TODO use FastAPIInstrumentor once Motel supports traces.
    # For now, manually configure uvicorn.
    logging.getLogger("uvicorn").setLevel(console_level)
    # Explicit levels to reduce noise
    logging.getLogger("sse_starlette.sse").setLevel(
        max(logger_level, logging.INFO)
    )
    logger.info(
        "Logging initialized: Console: %s, File: %s, Telemetry: %s",
        console_level,
        file_level,
        otlp_level,
    )
