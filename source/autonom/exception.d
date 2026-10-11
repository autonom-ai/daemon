module autonom.exception;

/// A caller supplied invalid data; HTTP endpoints map this to 400.
class InvalidInput : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// An operation conflicts with current ownership or lifecycle state; HTTP maps this to 409.
class Conflict : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// A backend operation failed; HTTP hides implementation details with status 503.
class BackendFailure : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}
