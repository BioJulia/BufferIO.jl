@testset "IOWriter construction and type" begin
    # Test basic construction with VecWriter
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    @test io_writer isa IOWriter{VecWriter}
    @test io_writer isa IO

    # Test with BufWriter
    buf_writer = BufWriter(IOBuffer())
    io_buf = IOWriter(buf_writer)
    @test io_buf isa IOWriter{BufWriter{IOBuffer}}

    # Test with GenericBufWriter
    generic_writer = GenericBufWriter()
    io_generic = IOWriter(generic_writer)
    @test io_generic isa IOWriter{GenericBufWriter}
end

@testset "IOWriter forwarded methods" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    # Test close (VecWriter's close does nothing)
    close(io_writer)
    # Should be able to close multiple times
    close(io_writer)

    # Test flush (VecWriter's flush does nothing)
    flush(io_writer)
    flush(io_writer)

    # Test position and filesize with BufWriter (which implements them)
    inner_io = IOBuffer()
    buf_writer = BufWriter(inner_io)
    io_buf = IOWriter(buf_writer)

    @test position(io_buf) == 0
    @test filesize(io_buf) == 0

    write(io_buf, "test")
    @test position(io_buf) == 4
    @test filesize(io_buf) == 0  # Not flushed yet

    flush(io_buf)
    @test position(io_buf) == 4
    @test filesize(io_buf) == 4
end

@testset "IOWriter write UInt8" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    # Test writing single bytes
    @test write(io_writer, 0x41) == 1  # 'A'
    @test write(io_writer, 0x42) == 1  # 'B'
    @test write(io_writer, 0x43) == 1  # 'C'

    @test vec_writer.vec == b"ABC"

    # Test writing to BufWriter
    inner_io = IOBuffer()
    buf_writer = BufWriter(inner_io, 10)
    io_buf = IOWriter(buf_writer)

    @test write(io_buf, 0xFF) == 1
    flush(io_buf)
    seekstart(inner_io)
    @test read(inner_io, UInt8) == 0xFF
end

@testset "IOWriter write data" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    # Test writing array
    arr = UInt8[1, 2, 3, 4, 5]
    @test write(io_writer, arr) == 5
    @test vec_writer.vec[(end - 4):end] == arr

    # Test writing integers
    @test write(io_writer, htol(UInt16(0x1234))) == 2
    @test vec_writer.vec[(end - 1):end] == [0x34, 0x12]

    @test write(io_writer, htol(UInt32(0xABCDEF12))) == 4
    @test vec_writer.vec[(end - 3):end] == [0x12, 0xEF, 0xCD, 0xAB]

    # Test writing float
    @test write(io_writer, Float64(3.14)) == 8
    @test reinterpret(Float64, vec_writer.vec[(end - 7):end])[1] == 3.14

    # Test writing MemoryView
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)
    @test write(io_writer, MemoryView(b"abc")) == 3
    @test write(io_writer, MemoryView(b"d")) == 1
    @test write(io_writer, MemoryView(b"ef")) == 2
    @test vec_writer.vec == b"abcdef"
end

@testset "IOWriter write String" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    # Test basic string
    @test write(io_writer, "hello") == 5
    @test String(copy(vec_writer.vec)) == "hello"

    # Test more strings
    @test write(io_writer, " world") == 6
    @test String(copy(vec_writer.vec)) == "hello world"

    # Test empty string
    prev_len = length(vec_writer.vec)
    @test write(io_writer, "") == 0
    @test length(vec_writer.vec) == prev_len

    # Test SubString
    str = "Hello, World!"
    substr = SubString(str, 8, 12)  # "World"
    vec_writer2 = VecWriter()
    io_writer2 = IOWriter(vec_writer2)
    @test write(io_writer2, substr) == 5
    @test String(vec_writer2.vec) == "World"

    # Test Unicode string
    vec_writer3 = VecWriter()
    io_writer3 = IOWriter(vec_writer3)
    unicode_str = "Hello 世界"
    n = write(io_writer3, unicode_str)
    @test n == sizeof(unicode_str)
    @test String(vec_writer3.vec) == unicode_str
end

@testset "IOWriter write Char" begin
    io_writer = IOWriter(VecWriter())
    @test write(io_writer, 'a', 'æ') == 3
    @test write(io_writer, '\0') == 1
    @test write(io_writer, '北') == 3
    @test String(io_writer.x.vec) == "aæ\0北"
end

@testset "IOWriter write CodeUnits" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    # Test writing codeunits
    str = "test string"
    units = codeunits(str)
    @test write(io_writer, units) == sizeof(str)
    @test String(vec_writer.vec) == str

    # Test with substring's codeunits
    vec_writer2 = VecWriter()
    io_writer2 = IOWriter(vec_writer2)
    substr = SubString("Hello, World!", 1, 5)
    units2 = codeunits(substr)
    @test write(io_writer2, units2) == 5
    @test String(vec_writer2.vec) == "Hello"
end

@testset "IOWriter write multiple arguments" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    # Test writing multiple items at once
    n = write(io_writer, 0x41, 0x42, 0x43)
    @test n == 3
    @test vec_writer.vec[(end - 2):end] == b"ABC"

    # Test writing mixed types
    vec_writer2 = VecWriter()
    io_writer2 = IOWriter(vec_writer2)
    n2 = write(io_writer2, "Hello", 0x20, "World")
    @test n2 == 11  # 5 + 1 + 5
    @test String(vec_writer2.vec) == "Hello World"

    # Test with numbers and strings
    vec_writer3 = VecWriter()
    io_writer3 = IOWriter(vec_writer3)
    n3 = write(io_writer3, UInt8(1), UInt8(2), UInt8(3), UInt8(4))
    @test n3 == 4
    @test vec_writer3.vec == [1, 2, 3, 4]
end

@testset "IOWriter seek with BufWriter wrapping IOBuffer" begin
    inner_io = IOBuffer()
    buf_writer = BufWriter(inner_io)
    io_writer = IOWriter(buf_writer)

    # Write initial data and flush
    write(io_writer, "0123456789")
    flush(io_writer)
    @test position(io_writer) == 10
    @test filesize(io_writer) == 10

    # Seek to beginning
    result = seek(io_writer, 0)
    @test result === io_writer  # seek returns the IOWriter itself
    @test position(io_writer) == 0

    # Overwrite data at beginning
    write(io_writer, "AB")
    flush(io_writer)
    seekstart(inner_io)
    @test read(inner_io, String) == "AB23456789"

    # Seek to middle
    seek(io_writer, 5)
    @test position(io_writer) == 5
    write(io_writer, "XYZ")
    flush(io_writer)
    seekstart(inner_io)
    @test read(inner_io, String) == "AB234XYZ89"

    # Seek to end
    seek(io_writer, filesize(io_writer))
    @test position(io_writer) == filesize(io_writer)
    @test position(io_writer) == 10
    write(io_writer, "END")
    flush(io_writer)
    seekstart(inner_io)
    @test read(inner_io, String) == "AB234XYZ89END"
    @test filesize(io_writer) == 13

    # Seek with buffered (unflushed) data
    seek(io_writer, 0)
    write(io_writer, "HELLO")  # Not flushed yet
    @test position(io_writer) == 5  # Position includes buffered data
    @test filesize(io_writer) == 13  # Filesize doesn't include buffered data
end

@testset "IOWriter printing" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    print(io_writer, 123)
    println(io_writer, "Hello, ", "world!")

    @test String(vec_writer.vec) == "123Hello, world!\n"
end

@testset "Unsafe write" begin
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)
    io = IOBuffer()

    for i in Any[
            "abc",
            "defg",
            [1, 2],
            [0x01, 0x07, 0x03],
        ]
        GC.@preserve i begin
            ptr = Ptr{UInt8}(pointer(i))
            n = UInt(sizeof(i))
            unsafe_write(io_writer, ptr, n)
            unsafe_write(io, ptr, n)
        end
    end

    @test take!(io) == vec_writer.vec
end

@testset "IOWriter edge cases" begin
    # Test writing empty data
    vec_writer = VecWriter()
    io_writer = IOWriter(vec_writer)

    @test write(io_writer, UInt8[]) == 0
    @test isempty(vec_writer.vec)

    @test write(io_writer, "") == 0
    @test isempty(vec_writer.vec)

    # Test print with no arguments
    @test isempty(vec_writer.vec)

    # Test multiple close/flush calls
    close(io_writer)
    close(io_writer)
    flush(io_writer)
    flush(io_writer)

    # Write after close (VecWriter allows this)
    write(io_writer, "still works")
    @test String(vec_writer.vec) == "still works"
end
