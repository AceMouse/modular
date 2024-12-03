# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from sys.param_env import env_get_string, is_defined

from gpu.host import DeviceContext


fn expect_eq[
    type: DType, size: Int
](val: SIMD[type, size], expected: SIMD[type, size], msg: String = "") raises:
    if val != expected:
        raise Error("expect_eq failed: " + msg)


fn expect_eq(val: Bool, expected: Bool, msg: String = "") raises:
    if val != expected:
        raise Error("expect_eq failed: " + msg)


fn api() -> String:
    @parameter
    if is_defined["MODULAR_ASYNCRT_DEVICE_CONTEXT_V2"]():
        alias api = env_get_string["MODULAR_ASYNCRT_DEVICE_CONTEXT_V2"]()

        @parameter
        if api == "gpu":
            return DeviceContext.device_api
        return api
    return "default"


fn create_test_device_context(
    *, device_id: Int = 0, buffer_cache_size: UInt = 0
) raises -> DeviceContext:
    # Create an instance of the DeviceContext
    var test_ctx: DeviceContext

    @parameter
    if is_defined["MODULAR_ASYNCRT_DEVICE_CONTEXT_V2"]():
        print("Using DeviceContext: V2 - " + api())
        test_ctx = DeviceContext(
            device_id=device_id, api=api(), buffer_cache_size=buffer_cache_size
        )
    elif is_defined["MODULAR_ASYNCRT_DEVICE_CONTEXT_V1"]():
        raise Error("DeviceContextV1 is unsupported")
    else:
        print("Using DeviceContext: default")
        test_ctx = DeviceContext(
            device_id=device_id, buffer_cache_size=buffer_cache_size
        )

    return test_ctx
