module autonom.exception;

import std.exception : basicExceptionCtors;

class InvalidInputException : Exception
{
    mixin basicExceptionCtors;
}

class ConflictException : Exception
{
    mixin basicExceptionCtors;
}

class BackendException : Exception
{
    mixin basicExceptionCtors;
}
