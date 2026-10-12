@testset "IOReader construction and type" begin
    # Test basic construction
    cursor = CursorReader("hello world")
    io_reader = IOReader(cursor)

    @test io_reader isa IOReader{CursorReader}
    @test io_reader isa IO

    # Test with empty data
    empty_cursor = CursorReader("")
    empty_io = IOReader(empty_cursor)
    @test empty_io isa IOReader{CursorReader}
    @test eof(empty_io)
end

@testset "Some forwarded methods" begin
    cursor = CursorReader("test data for forwarding")
    io_reader = IOReader(cursor)

    # Test bytesavailable
    @test bytesavailable(io_reader) == bytesavailable(cursor)

    # Test eof
    @test eof(io_reader) == eof(cursor)
    @test !eof(io_reader)

    # Read some data and test eof again
    v = read(io_reader, 5)
    @test v == b"test "
    @test eof(io_reader) == eof(cursor)
    @test !eof(io_reader)

    # Read all remaining data
    v = read(io_reader)
    @test v == b"data for forwarding"
    @test eof(io_reader) == eof(cursor)
    @test eof(io_reader)

    # Test position
    seek(io_reader, 5)
    @test position(io_reader) == position(cursor)
    @test position(io_reader) == 5

    # Test filesize
    @test filesize(io_reader) == filesize(cursor)

    # Test close
    @test isopen(io_reader)
    close(io_reader)  # Should forward to cursor's close (which does nothing)
    @test isopen(io_reader)
end

@testset "IOReader read methods" begin
    cursor = CursorReader("Hello, World!")
    io_reader = IOReader(cursor)

    # Test read(UInt8)
    @test read(io_reader, UInt8) == UInt8('H')
    @test position(io_reader) == 1

    # Test read(n::Integer)
    data_chunk = read(io_reader, 4)
    @test data_chunk == b"ello"
    @test position(io_reader) == 5

    # Test readavailable
    available = readavailable(io_reader)
    @test available == b", World!"
    @test eof(io_reader)

    # Test read() - all data
    cursor2 = CursorReader("all data")
    io_reader2 = IOReader(cursor2)
    data = read(io_reader2)
    @test data == b"all data"
    @test eof(io_reader2)

    # Test read(String)
    cursor3 = CursorReader("string test")
    io_reader3 = IOReader(cursor3)
    str = read(io_reader3, String)
    @test str == "string test"
    @test eof(io_reader3)

    # Test peek
    cursor4 = CursorReader("peek test")
    io_reader4 = IOReader(cursor4)
    @test peek(io_reader4) == UInt8('p')
    @test read(io_reader4, 3) == b"pee"
    @test peek(io_reader4) == UInt8('k')
    @test read(io_reader4) == b"k test"
    @test_throws EOFError peek(io_reader4)
end

@testset "IOReader unsafe_read" begin
    cursor = CursorReader("unsafe read test")
    io_reader = IOReader(cursor)

    # Test with array
    arr = Vector{UInt8}(undef, 6)
    GC.@preserve arr begin
        unsafe_read(io_reader, pointer(arr), UInt(6))
    end
    @test arr == b"unsafe"
    @test position(io_reader) == 6

    # Test reading more than available
    remaining_size = filesize(io_reader) - position(io_reader)
    arr2 = Vector{UInt8}(undef, 20)
    GC.@preserve arr2 begin
        @test_throws EOFError unsafe_read(io_reader, pointer(arr2), UInt(20))
    end

    # Test with empty reader
    empty_cursor = CursorReader("")
    empty_io = IOReader(empty_cursor)
    arr3 = fill!(Vector{UInt8}(undef, 5), 0xaa)
    GC.@preserve arr3 begin
        unsafe_read(empty_io, pointer(arr3), UInt(0))
    end
    @test all(==(0xaa), arr3)
end

@testset "IOReader read!" begin
    cursor = CursorReader("read into array")
    io_reader = IOReader(cursor)

    # Test reading into exact size array
    arr = Vector{UInt8}(undef, 4)
    result = read!(io_reader, arr)
    @test result === arr
    @test arr == b"read"
    @test position(io_reader) == 4

    # Test reading into larger array
    arr2 = Vector{UInt8}(undef, 20)
    remaining_data = b" into array"
    read!(io_reader, view(arr2, 1:length(remaining_data)))
    @test arr2[1:length(remaining_data)] == remaining_data
    @test eof(io_reader)

    # Test reading from empty reader (should throw EOF error)
    empty_cursor = CursorReader("")
    empty_io = IOReader(empty_cursor)
    arr3 = Vector{UInt8}(undef, 1)
    @test_throws EOFError read!(empty_io, arr3)

    # Test reading more than available (should throw EOF error)
    cursor2 = CursorReader("ab")
    io_reader2 = IOReader(cursor2)
    arr4 = Vector{UInt8}(undef, 5)
    @test_throws EOFError read!(io_reader2, arr4)

    # Test generic array
    cursor3 = CursorReader("abcde")
    io_reader3 = IOReader(cursor3)
    arr5 = Test.GenericArray([0x01, 0x02, 0x03])
    read!(io_reader3, arr5)
    @test arr5 == b"abc"
end

@testset "IOReader readbytes!" begin
    cursor = CursorReader("readbytes test data")
    io_reader = IOReader(cursor)

    # Test reading exact amount
    buf = UInt8[]
    n_read = readbytes!(io_reader, buf, 9)
    @test n_read == 9
    @test buf == b"readbytes"
    @test position(io_reader) == 9

    # Test trying to read more than available
    buf2 = UInt8[]
    n_read2 = readbytes!(io_reader, buf2, 100)
    @test n_read2 == 10  # " test data" remaining
    @test buf2 == b" test data"
    @test eof(io_reader)

    # Test readbytes will grows buffer
    cursor2 = CursorReader("buffer test")
    io_reader2 = IOReader(cursor2)
    buf3 = Vector{UInt8}(undef, 3)
    n_read3 = readbytes!(io_reader2, buf3, 6)
    @test n_read3 == 6
    @test buf3 == b"buffer"

    # Test default nb parameter (should use length(b))
    buf4 = Vector{UInt8}(undef, 4)
    n_read4 = readbytes!(io_reader2, buf4)  # No nb parameter
    @test n_read4 == 4
    @test buf4 == b" tes"

    # Test will not try to shrink buffer
    buf5 = fill(0xaa, 5)
    io_reader3 = IOReader(CursorReader("hi!"))
    n_read5 = readbytes!(io_reader3, buf5)
    @test n_read5 == 3
    @test buf5 == b"hi!\xaa\xaa"

    # Test MutableMemoryView (previously ambiguous with MemoryViews' method)
    mem = fill(0xaa, 5)
    io_reader4 = IOReader(CursorReader("abcdefg"))
    n_read6 = readbytes!(io_reader4, MemoryView(mem), 3)
    @test n_read6 == 3
    @test mem == b"abc\xaa\xaa"
    n_read7 = readbytes!(io_reader4, MemoryView(mem))
    @test n_read7 == 4
    @test mem == b"defg\xaa"
end

@testset "IOReader readline" begin
    cursor = CursorReader("line1\nline2\r\nline3\nlast")
    io_reader = IOReader(cursor)

    # Test readline without keep
    @test readline(io_reader) == "line1"
    @test readline(io_reader) == "line2"
    @test readline(io_reader) == "line3"
    @test readline(io_reader) == "last"
    @test eof(io_reader)

    # Test with keep=true
    cursor2 = CursorReader("keep\ntest\r\n")
    io_reader2 = IOReader(cursor2)
    @test readline(io_reader2; keep = true) == "keep\n"
    @test readline(io_reader2; keep = true) == "test\r\n"
    @test eof(io_reader2)

    # Test with keep=false explicitly
    cursor3 = CursorReader("explicit\ntest")
    io_reader3 = IOReader(cursor3)
    @test readline(io_reader3; keep = false) == "explicit"
    @test readline(io_reader3; keep = false) == "test"
end

@testset "IOReader copyuntil" begin
    cursor = CursorReader("copy,until,delimiter,test")
    io_reader = IOReader(cursor)
    output = IOBuffer()

    # Test copyuntil without keep
    result = copyuntil(output, io_reader, UInt8(','))
    @test result === output
    @test String(take!(output)) == "copy"
    @test read(io_reader, UInt8) == UInt8('u')  # Should be at 'u' after delimiter

    # Test copyuntil with keep
    copyuntil(output, io_reader, UInt8(','); keep = true)
    @test String(take!(output)) == "ntil,"

    # Test copyuntil when delimiter not found (should copy to end)
    copyuntil(output, io_reader, UInt8('!'))
    @test String(take!(output)) == "delimiter,test"
    @test eof(io_reader)
end

@testset "IOReader copyline" begin
    cursor = CursorReader("first line\nsecond line\r\nthird")
    io_reader = IOReader(cursor)
    output = IOBuffer()

    # Test copyline without keep
    copyline(output, io_reader)
    @test String(take!(output)) == "first line"

    # Test copyline with keep=true
    copyline(output, io_reader; keep = true)
    @test String(take!(output)) == "second line\r\n"

    # Test copyline with no trailing newline
    copyline(output, io_reader; keep = false)
    @test String(take!(output)) == "third"
    @test eof(io_reader)
end

@testset "IOReader readuntil" begin
    cursor = CursorReader("read#until#delimiter#end")
    io_reader = IOReader(cursor)

    # Test readuntil without keep
    result = readuntil(io_reader, UInt8('#'))
    @test result == b"read"

    # Test readuntil with keep=true
    result2 = readuntil(io_reader, UInt8('#'); keep = true)
    @test result2 == b"until#"

    # Test readuntil when delimiter not found
    result3 = readuntil(io_reader, UInt8('@'))
    @test result3 == b"delimiter#end"
    @test eof(io_reader)
end
