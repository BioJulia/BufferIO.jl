@testset "CursorReader construction" begin
    # Test with String
    reader = CursorReader("hello world")
    @test reader isa CursorReader
    @test position(reader) == 0
    @test filesize(reader) == 11
    @test !eof(reader)

    # Test with empty string
    empty_reader = CursorReader("")
    @test position(empty_reader) == 0
    @test filesize(empty_reader) == 0
    @test eof(empty_reader)

    # Test with byte array
    bytes = UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f]  # "Hello"
    reader_bytes = CursorReader(bytes)
    @test filesize(reader_bytes) == 5
    @test position(reader_bytes) == 0

    # Test with Memory
    mem = Memory{UInt8}(undef, 4)
    mem[1:4] .= [0x61, 0x62, 0x63, 0x64]  # "abcd"
    reader_mem = CursorReader(mem)
    @test filesize(reader_mem) == 4
    @test position(reader_mem) == 0
end

@testset "CursorReader basic position and seek" begin
    reader = CursorReader("abcdefghijk")

    # Initial position should be 0
    @test position(reader) == 0

    # Read some bytes and check position
    @test read(reader, UInt8) == UInt8('a')
    @test position(reader) == 1

    @test read(reader, 3) == b"bcd"
    @test position(reader) == 4

    # Seek to beginning
    seek(reader, 0)
    @test position(reader) == 0
    @test read(reader, UInt8) == UInt8('a')

    # Seek to middle
    seek(reader, 5)
    @test position(reader) == 5
    @test read(reader, UInt8) == UInt8('f')
    @test position(reader) == 6

    # Seek to end
    seek(reader, filesize(reader))
    @test position(reader) == filesize(reader)
    @test eof(reader)

    # Seek back from end
    seek(reader, filesize(reader) - 1)
    @test position(reader) == filesize(reader) - 1
    @test read(reader, UInt8) == UInt8('k')
    @test eof(reader)

    reader = CursorReader("test")

    # Valid seeks
    @test seek(reader, 0) === reader
    @test position(reader) == 0

    @test seek(reader, 2) === reader
    @test position(reader) == 2

    @test seek(reader, 4) === reader
    @test position(reader) == 4
    @test eof(reader)

    # Invalid seeks - should throw IOError with BadSeek
    @test_throws IOError seek(reader, -1)
    @test_throws IOError seek(reader, 5)  # Beyond end
    @test_throws IOError seek(reader, 100)

    # Seekstart and end
    reader = CursorReader("hello, world!")
    read(reader, 4)
    @test peek(reader) == UInt8('o')
    seekstart(reader)
    @test read(reader, UInt8) == UInt8('h')
    seekend(reader)
    @test eof(reader)
    seekstart(reader)
    @test read(reader) == b"hello, world!"

    # Verify error kind
    try
        seek(reader, -1)
    catch e
        @test e isa IOError
        @test e.kind == IOErrorKinds.BadSeek
    end

    try
        seek(reader, 10)  # filesize is 4
    catch e
        @test e isa IOError
        @test e.kind == IOErrorKinds.BadSeek
    end

    # Relative seek
    reader = CursorReader("0123456789")
    relative_seek(reader, 4)
    @test read(reader, UInt8) == UInt8('4')
    relative_seek(reader, -2)
    @test read(reader, UInt8) == UInt8('3')
    relative_seek(reader, 6)
    @test eof(reader)
    relative_seek(reader, -7)
    @test read(reader, UInt8) == UInt8('3')
    @test_throws IOError relative_seek(reader, -5)
end

@testset "read_all!" begin
    s = "abcdefghijklmnoq"
    c = CursorReader(s)
    mem = MemoryView(zeros(UInt8, 25))
    @test read_all!(c, mem) == ncodeunits(s)
    @test mem[1:ncodeunits(s)] == codeunits(s)
end

@testset "Misc cursor" begin
    io = CursorReader("abcef")
    @test read(io, UInt8) == UInt8('a')
    close(io) # do nothing
    @test fill_buffer(io) == 0
    @test read(io, UInt8) == UInt8('b')

    consume(io, 2)
    @test peek(io, UInt8) == UInt8('f')
    @test_throws IOError consume(io, -1)
    @test_throws IOError consume(io, 2)
    consume(io, 1)
    @test eof(io)
end
