@testset "read_into!" begin
    io = GenericBufReader([0x01, 0x02, 0x03, 0x04, 0x05])
    v = MemoryView(collect(0x06:0x08))
    @test read_into!(io, v) == 3
    @test v == 1:3
    @test read_into!(io, v) == 2
    @test v == [4, 5, 3]
    @test eof(io)

    # Empty io
    io = GenericBufReader(UInt8[])
    v = MemoryView(collect(0x06:0x09))
    @test iszero(read_into!(io, v))
    @test v == 6:9

    # Empty v
    io = GenericBufReader([0x01, 0x02, 0x03, 0x04, 0x05])
    v = MemoryView(collect(0x06:0x05))
    @test iszero(read_into!(io, v))
    @test isempty(v)
    @test read(io) == 1:5

    # With partial buffering
    io = BufReader(IOBuffer("hello world"), 3)
    v = MemoryView(collect(0x01:0x08))
    # Fill explicitly, since an empty buffer smaller than `v` is bypassed
    fill_buffer(io)
    @test read_into!(io, v) == 3
    @test v == b"hel\4\5\6\7\x8"
    fill_buffer(io)
    @test read_into!(io, v) == 3
    @test v == b"lo \4\5\6\7\x8"
    resize_buffer(io, 100)
    @test read_into!(io, v) == 5
    @test v == b"world\6\7\x8"
end

@testset "read_all!" begin
    io = BufReader(IOBuffer("hello world"), 3)
    v = MemoryView(collect(0x01:0x08))
    @test read_all!(io, v) == 8
    @test v == b"hello wo"
    @test read_all!(io, v) == 3
    @test v == b"rldlo wo"

    io = BufReader(IOBuffer("hello world"), 3)
    v = MemoryView(collect(0x01:0x0f))
    @test read_all!(io, v) == 11
    @test v == UInt8[b"hello world"; [12, 13, 14, 15]]
end

@testset "bytesavailable" begin
    @test bytesavailable(CursorReader("abcde")) == 5
    @test bytesavailable(CursorReader("")) == 0

    io = BufReader(IOBuffer("abcdefghij"))
    @test bytesavailable(io) == 0
    fill_buffer(io)
    @test bytesavailable(io) == 10
end

@testset "read(::T, UInt8)" begin
    io = GenericBufReader("abcde")
    @test [read(io, UInt8) for i in 1:5] == b"abcde"
    @test_throws IOError read(io, UInt8)

    @test_throws IOError read(GenericBufReader(b""), UInt8)
end

@testset "read(::T)" begin
    io = GenericBufReader([0x01, 0x02, 0x03, 0x04, 0x05])
    v = read(io)
    @test v isa Vector{UInt8}
    @test v == b"\1\2\3\4\5"
    v = read(io)
    @test v isa Vector{UInt8}
    @test isempty(v)
end

@testset "read(::T, ::Integer)" begin
    v = view(b"abcdefghijklm", 3:10)
    io = GenericBufReader(v)
    @test read(io, 3) == b"cde"
    @test read(io, 1) == b"f"
    @test read(io, 5) == b"ghij"
    @test read(io, 1) == UInt8[]
    @test_throws ArgumentError read(io, -1)

    io = GenericBufReader("abcde")
    @test read(io, 500) == b"abcde"
end

@testset "read(::T, String)" begin
    io = GenericBufReader([0x01 0x03; 0x02 0x04])
    @test read(io, String) === "\1\2\3\4"
    @test read(io, String) === ""
    @test read(GenericBufReader(UInt8[]), String) === ""
end


@testset "eof" begin
    io = GenericBufReader("abc")
    @test !eof(io)

    # Read all data
    read(io)
    @test eof(io)

    # Empty reader is EOF
    empty_io = GenericBufReader("")
    @test eof(empty_io)
end

@testset "unsafe_read_all!" begin
    io = GenericBufReader("hello")

    # Test with array
    arr = Vector{UInt8}(undef, 3)
    n_read = GC.@preserve arr unsafe_read_all!(io, pointer(arr), 3)
    @test n_read == 3
    @test arr == b"hel"

    # Test reading more than available
    arr2 = Vector{UInt8}(undef, 10)
    n_read2 = GC.@preserve arr2 unsafe_read_all!(io, pointer(arr2), 10)
    @test n_read2 == 2  # Only "lo" remaining
    @test arr2[1:2] == b"lo"

    # Test with empty reader
    empty_io = GenericBufReader("")
    arr3 = Vector{UInt8}(undef, 5)
    n_read3 = GC.@preserve arr3 unsafe_read_all!(empty_io, pointer(arr3), 5)
    @test n_read3 == 0

    # Negative `nbytes` throws, without reading
    io4 = GenericBufReader("abcdef")
    arr4 = Vector{UInt8}(undef, 4)
    GC.@preserve arr4 begin
        @test_throws ArgumentError unsafe_read_all!(io4, pointer(arr4), -1)
        @test unsafe_read_all!(io4, pointer(arr4), 4) == 4
    end
    @test arr4 == b"abcd"

    # The reader's buffer is too short to hold the data, so it is read in chunks
    data = collect(UInt8, 1:16)
    arr5 = zeros(UInt8, 16)
    @test GC.@preserve(arr5, unsafe_read_all!(BoundedReader(data, 3), pointer(arr5), 16)) == 16
    @test arr5 == data

    # Stop at EOF, when reading in chunks
    arr6 = zeros(UInt8, 4)
    @test GC.@preserve(arr6, unsafe_read_all!(BoundedReader(b"ab", 1), pointer(arr6), 4)) == 2
    @test arr6 == [0x61, 0x62, 0x00, 0x00]

    # Only bytes are read, and only into a pointer
    @test_throws MethodError unsafe_read_all!(GenericBufReader(data), Ref{UInt64}(0), 8)
    @test_throws MethodError unsafe_read_all!(GenericBufReader(data), zeros(UInt8, 8), 8)
    floats = [0.0, 0.0]
    @test_throws MethodError GC.@preserve(floats, unsafe_read_all!(GenericBufReader(data), pointer(floats), 16))

end

@testset "unsafe_read" begin
    data = collect(UInt8, 1:16)
    for make in [() -> GenericBufReader(data), () -> BoundedReader(data, 3), () -> CursorReader(data)]
        arr = zeros(UInt8, 20)
        GC.@preserve arr begin
            reader = make()
            @test unsafe_read(reader, pointer(arr), UInt(5)) === nothing
            @test arr[1:5] == data[1:5]
            # Any `Integer` is accepted
            @test unsafe_read(reader, pointer(arr, 6), Int32(6)) === nothing
            @test arr[1:11] == data[1:11]
            @test unsafe_read(reader, pointer(arr), 0) === nothing
            # Copies all available bytes, then throws, if `io` is EOF before `nbytes` bytes
            @test try
                unsafe_read(reader, pointer(arr, 12), 9)
                false
            catch e
                e isa IOError && e.kind == IOErrorKinds.EOF
            end
            @test arr[1:16] == data
            @test eof(reader)
            @test unsafe_read(reader, pointer(arr), 0) === nothing
            @test_throws IOError unsafe_read(reader, pointer(arr), 1)
            @test_throws InexactError unsafe_read(make(), pointer(arr), -1)
        end
    end

    # Only bytes are read, and only into a pointer
    @test_throws MethodError unsafe_read(GenericBufReader(data), Ref{UInt64}(0), 8)
    @test_throws MethodError unsafe_read(GenericBufReader(data), zeros(UInt8, 8), 8)
    floats = [0.0, 0.0]
    @test_throws MethodError GC.@preserve(floats, unsafe_read(GenericBufReader(data), pointer(floats), 16))
end

@testset "readavailable" begin
    io = GenericBufReader("hello")

    # First call should read all available data
    result = readavailable(io)
    @test result == b"hello"

    # Second call should return empty
    @test readavailable(io) == UInt8[]

    # Empty reader
    empty_io = GenericBufReader("")
    @test readavailable(empty_io) == UInt8[]
end

@testset "peek(::T, ::Type{UInt8})" begin
    io = GenericBufReader("abc")

    # Peek should not advance position
    @test peek(io, UInt8) == UInt8('a')
    @test peek(io, UInt8) == UInt8('a')  # Same byte

    # Now read and peek next
    read(io, UInt8)
    @test peek(io, UInt8) == UInt8('b')

    # Read remaining
    read(io, UInt8)
    read(io, UInt8)

    # Peek at EOF should throw
    @test_throws IOError peek(io, UInt8)

    # Empty reader should throw
    empty_io = GenericBufReader("")
    @test_throws IOError peek(empty_io, UInt8)
end

@testset "readbytes!" begin
    # Test basic functionality
    io = GenericBufReader("hello world")
    buf = Vector{UInt8}(undef, 5)
    n_read = readbytes!(io, buf, 5)
    @test n_read == 5
    @test buf == b"hello"
    @test readbytes!(io, buf) == 5
    @test buf == b" worl"

    # Test with nb > length(b) - should expand buffer
    io = GenericBufReader("hello world")
    buf = Vector{UInt8}(undef, 3)
    n_read = readbytes!(io, buf, 6)
    @test n_read == 6
    @test length(buf) == 6
    @test buf == b"hello "

    # Test reading more than available
    io = GenericBufReader("hi")
    buf = Vector{UInt8}(undef, 10)
    n_read = readbytes!(io, buf, 10)
    @test n_read == 2
    @test buf[1:2] == b"hi"

    # Test default nb parameter
    io = GenericBufReader("test")
    buf = Vector{UInt8}(undef, 2)
    n_read = readbytes!(io, buf)  # Should read length(buf) = 2
    @test n_read == 2
    @test buf == b"te"

    # Test with empty reader
    empty_io = GenericBufReader("")
    buf = Vector{UInt8}(undef, 5)
    n_read = readbytes!(empty_io, buf, 5)
    @test n_read == 0
end

@testset "read!" begin
    # Test exact fill
    io = GenericBufReader("hello")
    arr = Vector{UInt8}(undef, 5)
    result = read!(io, arr)
    @test result === arr
    @test arr == b"hello"

    # Test EOF before filling - should throw
    io2 = GenericBufReader("hi")
    arr2 = Vector{UInt8}(undef, 5)
    @test_throws IOError read!(io2, arr2)

    # Test with empty array
    io3 = GenericBufReader("test")
    empty_arr = Vector{UInt8}(undef, 0)
    result3 = read!(io3, empty_arr)
    @test result3 === empty_arr
    @test isempty(empty_arr)

    # Test with matrix (should work with any AbstractArray)
    io4 = GenericBufReader("abcdef")
    mat = Matrix{UInt8}(undef, 2, 3)
    result4 = read!(io4, mat)
    @test result4 === mat
    @test vec(mat) == b"abcdef"
end

@testset "readline" begin
    # Test basic line reading
    io = GenericBufReader("hello\nworld\n")
    @test readline(io) == "hello"
    @test readline(io) == "world"
    @test readline(io) == ""  # EOF

    # Test with \r\n
    io2 = GenericBufReader("line1\r\nline2\r\n")
    @test readline(io2) == "line1"
    @test readline(io2) == "line2"

    # Test keep=true
    io3 = GenericBufReader("hello\nworld\r\n")
    @test readline(io3, keep = true) == "hello\n"
    @test readline(io3, keep = true) == "world\r\n"

    # Test no final newline
    io4 = GenericBufReader("hello\nworld")
    @test readline(io4) == "hello"
    @test readline(io4) == "world"

    # Test empty lines
    io5 = GenericBufReader("a\n\nb")
    @test readline(io5) == "a"
    @test readline(io5) == ""
    @test readline(io5) == "b"

    # Test empty input
    empty_io = GenericBufReader("")
    @test readline(empty_io) == ""
end

@testset "readuntil" begin
    # Test reading until delimiter
    io = GenericBufReader("hello,world,test")
    @test readuntil(io, UInt8(',')) == b"hello"
    @test readuntil(io, UInt8(',')) == b"world"
    @test readuntil(io, UInt8(',')) == b"test"  # No more delimiters

    # Test keep=true
    io2 = GenericBufReader("a;b;c")
    @test readuntil(io2, UInt8(';'), keep = true) == b"a;"
    @test readuntil(io2, UInt8(';'), keep = true) == b"b;"
    @test readuntil(io2, UInt8(';'), keep = true) == b"c"

    # Test delimiter not found
    io3 = GenericBufReader("no delimiter here")
    @test readuntil(io3, UInt8('|')) == b"no delimiter here"

    # Test empty input
    empty_io = GenericBufReader("")
    @test readuntil(empty_io, UInt8('x')) == b""
end

@testset "copyuntil" begin
    # Test basic copying until delimiter
    io_src = GenericBufReader("hello,world,test")
    io_dst = IOBuffer()

    result = copyuntil(io_dst, io_src, UInt8(','))
    @test result === io_dst
    seekstart(io_dst)
    @test String(read(io_dst)) == "hello"

    # Continue copying
    io_dst2 = IOBuffer()
    copyuntil(io_dst2, io_src, UInt8(','))
    seekstart(io_dst2)
    @test String(read(io_dst2)) == "world"

    # Copy remaining (no more delimiters)
    io_dst3 = IOBuffer()
    copyuntil(io_dst3, io_src, UInt8(','))
    seekstart(io_dst3)
    @test String(read(io_dst3)) == "test"

    # Test keep=true
    io_src2 = GenericBufReader("a;b;c")
    io_dst4 = IOBuffer()
    copyuntil(io_dst4, io_src2, UInt8(';'), keep = true)
    seekstart(io_dst4)
    @test String(read(io_dst4)) == "a;"

    # Test delimiter not found - should copy all remaining
    io_src3 = GenericBufReader("no delimiter")
    io_dst5 = IOBuffer()
    copyuntil(io_dst5, io_src3, UInt8('|'))
    seekstart(io_dst5)
    @test String(read(io_dst5)) == "no delimiter"

    # Test empty source
    empty_src = GenericBufReader("")
    io_dst6 = IOBuffer()
    copyuntil(io_dst6, empty_src, UInt8('x'))
    seekstart(io_dst6)
    @test String(read(io_dst6)) == ""

    # Test copying to VecWriter
    io_src4 = GenericBufReader("data|more")
    vec_dst = VecWriter()
    copyuntil(vec_dst, io_src4, UInt8('|'))
    @test String(vec_dst.vec) == "data"

    # Test with binary delimiter
    io_src5 = GenericBufReader([0x01, 0x02, 0xFF, 0x03, 0x04])
    io_dst7 = IOBuffer()
    copyuntil(io_dst7, io_src5, 0xFF)
    seekstart(io_dst7)
    @test read(io_dst7) == [0x01, 0x02]
end

@testset "copyline" begin
    @testset "Base.copyline basic functionality" begin
        # Test basic line copying with \n
        input_io = IOBuffer("hello\nworld\ntest")
        reader = BufReader(input_io)
        output_io = IOBuffer()

        result = copyline(output_io, reader)
        @test result === output_io
        @test String(take!(output_io)) == "hello"
        @test String(read(reader)) == "world\ntest"

        # Test line copying with \r\n
        input_io2 = IOBuffer("line1\r\nline2\r\n")
        reader2 = BufReader(input_io2)
        output_io2 = IOBuffer()

        copyline(output_io2, reader2)
        @test String(take!(output_io2)) == "line1"
        @test String(read(reader2)) == "line2\r\n"

        # Test copying last line without newline
        input_io3 = IOBuffer("first\nlast")
        reader3 = BufReader(input_io3)
        output_io3 = IOBuffer()

        # Skip first line
        copyline(output_io3, reader3)
        take!(output_io3)  # Clear output

        # Copy last line
        copyline(output_io3, reader3)
        @test String(take!(output_io3)) == "last"
        @test eof(reader3)

        # Test keeping \n
        input_io = IOBuffer("hello\nworld")
        reader = BufReader(input_io)
        output_io = IOBuffer()

        copyline(output_io, reader; keep = true)
        @test String(take!(output_io)) == "hello\n"
        @test String(read(reader)) == "world"

        # Test keeping \r\n
        input_io2 = IOBuffer("line1\r\nline2")
        reader2 = BufReader(input_io2)
        output_io2 = IOBuffer()

        copyline(output_io2, reader2; keep = true)
        @test String(take!(output_io2)) == "line1\r\n"
        @test String(read(reader2)) == "line2"
    end

    @testset "Base.copyline buffer boundary cases" begin
        # Test line spanning multiple buffer fills
        long_line = "a"^100 * "\n" * "b"^50
        input_io = IOBuffer(long_line)
        reader = BufReader(input_io, 10)  # Small buffer to force multiple fills
        output_io = IOBuffer()

        copyline(output_io, reader)
        @test String(take!(output_io)) == "a"^100
        @test String(read(reader)) == "b"^50

        # Test \r\n spanning buffer boundary
        # Put \r at end of one buffer, \n at start of next
        data = "x"^9 * "\r\n" * "after"
        input_io2 = IOBuffer(data)
        reader2 = BufReader(input_io2, 10)
        output_io2 = IOBuffer()

        copyline(output_io2, reader2; keep = false)
        @test String(take!(output_io2)) == "x"^9
        @test String(read(reader2)) == "after"

        # Test with keep=true
        input_io3 = IOBuffer(data)
        reader3 = BufReader(input_io3, 10)
        output_io3 = IOBuffer()

        copyline(output_io3, reader3; keep = true)
        @test String(take!(output_io3)) == "x"^9 * "\r\n"
        @test String(read(reader3)) == "after"

        # Test reader with only \r\n
        input_io3 = IOBuffer("\r\n")
        reader3 = BufReader(input_io3)
        output_io3 = IOBuffer()

        copyline(output_io3, reader3; keep = false)
        @test String(take!(output_io3)) == ""
        @test eof(reader3)

        # Test with keep=true
        input_io4 = IOBuffer("\r\n")
        reader4 = BufReader(input_io4)
        output_io4 = IOBuffer()

        copyline(output_io4, reader4; keep = true)
        @test String(take!(output_io4)) == "\r\n"
        @test eof(reader4)
    end

    @testset "Base.copyline with limited buffer" begin
        # Normal case
        rdr = BoundedReader("abc\r\ndef\r\n", 2)
        io = IOBuffer()
        copyline(io, rdr)
        seekstart(io)
        @test read(io) == b"abc"
        copyline(io, rdr)
        seekstart(io)
        @test read(io) == b"abcdef"

        # Length buffer == 1, but no \r\n
        rdr = BoundedReader("abc\ndef", 1)
        io = IOBuffer()
        copyline(io, rdr)
        seekstart(io)
        @test read(io) == b"abc"
        copyline(io, rdr)
        seekstart(io)
        @test read(io) == b"abcdef"

        # Length buffer 1 and \r\n but keep
        rdr = BoundedReader("abc\r\nab", 1)
        io = IOBuffer()
        copyline(io, rdr; keep = true)
        seekstart(io)
        @test read(io) == b"abc\r\n"

        # Length buffer == 1 and ends at \r
        rdr = BoundedReader("abc\r", 1)
        io = IOBuffer()
        copyline(io, rdr; keep = false)
        @test take!(io) == b"abc\r"
        @test eof(rdr)

        # Length buffer == 1 and \r\n
        rdr = BoundedReader("abc\r\nab", 1)
        io = IOBuffer()
        copyline(io, rdr; keep = false)
        @test take!(io) == b"abc"
        copyline(io, rdr; keep = false)
        @test take!(io) == b"ab"

        # Length buffer == 1 and \r not followed by \n
        rdr = BoundedReader("a\rb\r\r\r\n\rc", 1)
        io = IOBuffer()
        copyline(io, rdr; keep = false)
        @test take!(io) == b"a\rb\r\r"
        copyline(io, rdr; keep = false)
        @test take!(io) == b"\rc"
        @test eof(rdr)

        # Stream ends at \r, which is alone in the buffer when it's filled.
        # `BoundedReader` invalidates the old buffer on `fill_buffer`, so this
        # checks that copyline does not write from the stale buffer.
        for keep in (false, true)
            rdr = BoundedReader("ab\r", 2)
            io = IOBuffer()
            copyline(io, rdr; keep)
            @test take!(io) == b"ab\r"
        end

        # Length == 1, but buffer can grow
        rdr = BufReader(IOBuffer("abc\r\n"), 1)
        io = IOBuffer()
        copyline(io, rdr; keep = false)
        seekstart(io)
        @test read(io) == b"abc"
    end
end

@testset "discard_all" begin
    # Test basic discarding
    reader = CursorReader("hello world")
    n_discarded = discard_all(reader, 5)
    @test n_discarded == 5
    @test position(reader) == 5
    @test String(read(reader)) == " world"

    # Test discarding more than available
    reader2 = CursorReader("abc")
    n_discarded2 = discard_all(reader2, 10)
    @test n_discarded2 == 3  # Only 3 bytes available
    @test eof(reader2)
    @test read(reader2) == UInt8[]

    # Test discarding zero bytes
    reader3 = CursorReader("test")
    n_discarded3 = discard_all(reader3, 0)
    @test n_discarded3 == 0
    @test position(reader3) == 0
    @test String(read(reader3)) == "test"

    # Test discarding from middle of reader
    reader4 = CursorReader("abcdefgh")
    read(reader4, 3)  # Read "abc", now at position 3
    n_discarded4 = discard_all(reader4, 2)
    @test n_discarded4 == 2
    @test position(reader4) == 5
    @test String(read(reader4)) == "fgh"

    # Test discarding all remaining bytes
    reader5 = CursorReader("123456")
    read(reader5, 2)  # Read "12", now at position 2
    n_discarded5 = discard_all(reader5, 4)
    @test n_discarded5 == 4
    @test eof(reader5)

    # Test discarding from empty reader
    reader6 = CursorReader("")
    n_discarded6 = discard_all(reader6, 5)
    @test n_discarded6 == 0
    @test eof(reader6)

    @testset "discard_all error conditions" begin
        # Test negative discard amount with CursorReader
        reader = CursorReader("test")
        @test_throws ArgumentError discard_all(reader, -1)
        @test_throws ArgumentError discard_all(reader, -10)

        # Test negative discard amount with BufReader
        io = IOBuffer("test")
        reader2 = BufReader(io)
        @test_throws ArgumentError discard_all(reader2, -1)
        @test_throws ArgumentError discard_all(reader2, -10)

        # Verify error messages contain expected text
        try
            discard_all(CursorReader("test"), -5)
            error()
        catch e
            @test e isa ArgumentError
        end
    end

    @testset "discard_all edge cases" begin
        # Test discard with exactly buffer-sized chunks
        io = IOBuffer("12345678")  # 8 bytes
        reader = BufReader(io, 4)   # Buffer size 4
        n1 = discard_all(reader, 4)        # Discard exactly buffer size
        @test n1 == 4
        @test String(read(reader)) == "5678"

        # Test large discard amounts
        data = "x"^1000  # 1000 bytes
        reader3 = CursorReader(data)
        n2 = discard_all(reader3, 500)
        @test n2 == 500
        @test position(reader3) == 500
    end
end

@testset "skip" begin
    # `skip` seeks relative to the current position, and returns the reader
    for make in [() -> CursorReader("abcdefghij"), () -> BufReader(IOBuffer("abcdefghij"), 3)]
        reader = make()
        @test skip(reader, 4) === reader
        @test position(reader) == 4
        @test read(reader, UInt8) == UInt8('e')
        skip(reader, -3)
        @test String(read(reader, 2)) == "cd"
        skip(reader, 0)
        @test position(reader) == 4
        # Any `Integer` is accepted
        skip(reader, Int32(2))
        skip(reader, UInt8(1))
        @test String(read(reader)) == "hij"
        # Seeking beyond either end throws `BadSeek`
        skip(reader, -10)
        @test position(reader) == 0
        for offset in [-1, 11]
            @test try
                skip(reader, offset)
                false
            catch e
                e isa IOError && e.kind == IOErrorKinds.BadSeek
            end
        end
        @test position(reader) == 0
        skip(reader, 10)
        @test eof(reader)
    end

    # `skip` seeks, so it does not fall back to reading and discarding bytes
    @test_throws MethodError skip(BoundedReader("abc", 2), 1)
end

@testset "discard_exact" begin
    # Test discarding exact amount available
    io = IOBuffer("hello world")
    reader = BufReader(io)
    discard_exact(reader, 5)
    @test String(read(reader)) == " world"

    # Test discarding zero bytes
    io2 = IOBuffer("test")
    reader2 = BufReader(io2)
    discard_exact(reader2, 0)
    @test String(read(reader2)) == "test"

    # Test discarding across buffer boundaries
    io3 = IOBuffer("abcdefghijklmnop")
    reader3 = BufReader(io3, 4)  # Small buffer to force multiple reads
    discard_exact(reader3, 8)
    @test String(read(reader3)) == "ijklmnop"

    # Test discarding all bytes
    io4 = IOBuffer("123")
    reader4 = BufReader(io4)
    discard_exact(reader4, 3)
    @test eof(reader4)

    # Test discarding with very small buffer
    io5 = IOBuffer("abcdefghijk")
    reader5 = BufReader(io5, 1)
    discard_exact(reader5, 7)
    @test String(read(reader5)) == "hijk"

    # Test discarding from partially read buffer
    io6 = IOBuffer("0123456789")
    reader6 = BufReader(io6, 5)
    read(reader6, 3)  # Read first 3 bytes
    discard_exact(reader6, 4)  # Discard next 4
    @test String(read(reader6)) == "789"

    @testset "discard_exact error conditions" begin
        # Test discarding more than available with CursorReader
        reader = CursorReader("abc")
        @test_throws IOError discard_exact(reader, 5)

        # Verify it's EOF error
        try
            discard_exact(CursorReader("ab"), 3)
            @test false  # Should not reach here
        catch e
            @test e isa IOError
            @test e.kind == IOErrorKinds.EOF
        end

        # Test discarding more than available with BufReader
        io = IOBuffer("xyz")
        reader2 = BufReader(io)
        @test_throws IOError discard_exact(reader2, 10)

        # Test negative discard amount
        reader3 = CursorReader("test")
        @test_throws ArgumentError discard_exact(reader3, -1)

        io3 = IOBuffer("")
        reader6 = BufReader(io3)
        @test_throws IOError discard_exact(reader6, 1)

        # Test partial discard followed by discard_exact failure
        reader7 = CursorReader("hello")
        discard_all(reader7, 3)  # Discard "hel"
        @test_throws IOError discard_exact(reader7, 5)  # Try to discard 5 more, only 2 available
    end
end

@testset "close and isopen" begin
    # Each reader, and whether closing makes it unusable
    readers = [
        (() -> BufReader(IOBuffer("abc")), true),
        (() -> ExpandReader(BufReader(IOBuffer("abc"))), true),
        (() -> BoundedReader("abc", 2), true),
        (() -> CursorReader("abc"), false),
        (() -> GenericBufReader("abc"), false),
        (() -> BlockReader("abc", 2), false),
    ]
    for (make, closing_disables) in readers
        reader = make()
        @test isopen(reader)
        @test close(reader) === nothing
        @test isopen(reader) == !closing_disables
        # Closing is idempotent
        @test close(reader) === nothing
        @test isopen(reader) == !closing_disables
    end
end
