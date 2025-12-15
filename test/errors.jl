cursor = CursorReader("0123456789")

@test_throws(
    "Called `consume` with a negative amount, or larger than available buffer size",
    consume(cursor, 25)
)

@test_throws(
    "Invalid seek, possibly seek out of bounds",
    seek(cursor, 25)
)

seekend(cursor)

@test_throws(
    "End of file",
    peek(cursor)
)

bounded = BoundedReader("012345\r\n6789", 1)
iobuf = IOBuffer()

@test_throws(
    "Buffer of reader or writer is too short for operation",
    copyline(iobuf, bounded)
)
