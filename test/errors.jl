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
