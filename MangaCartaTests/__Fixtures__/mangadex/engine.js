(function () {
  "use strict";

  function fail(code, message, retryAfterSeconds) {
    var error = { code: code, message: message };
    if (typeof retryAfterSeconds === "number") { error.retryAfterSeconds = retryAfterSeconds; }
    return { ok: false, error: error };
  }

  async function invoke(operation, request, context) {
    return fail("unsupported", operation + " is not implemented by this engine");
  }

  registerEngine("mangadexApi", { invoke: invoke });
})();
