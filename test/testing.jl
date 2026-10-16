@testset "BoundedReader" begin
    @test_throws ArgumentError BoundedReader("abc", 0)
    @test_throws ArgumentError BoundedReader("abc", 2; max_fill = 0)

    # Default max_fill is 1
    rdr = BoundedReader("abcdef", 3)
    @test isempty(get_buffer(rdr))
    @test fill_buffer(rdr) == 1
    @test fill_buffer(rdr) == 1
    @test fill_buffer(rdr) == 1
    @test fill_buffer(rdr) === nothing
    @test get_buffer(rdr) == b"abc"

    # Partial fill when reaching max buffer size
    rdr = BoundedReader("abcdef", 5; max_fill = 3)
    @test fill_buffer(rdr) == 3
    @test fill_buffer(rdr) == 2
    @test fill_buffer(rdr) === nothing
    @test get_buffer(rdr) == b"abcde"

    # Consume, and refill after consuming
    @test_throws IOError consume(rdr, 6)
    @test_throws IOError consume(rdr, -1)
    consume(rdr, 4)
    @test get_buffer(rdr) == b"e"
    @test fill_buffer(rdr) == 1
    @test get_buffer(rdr) == b"ef"
    # EOF
    @test fill_buffer(rdr) == 0
    consume(rdr, 2)
    @test fill_buffer(rdr) == 0
    @test isempty(get_buffer(rdr))

    # Never returns nothing on empty buffer, even with max size 1
    rdr = BoundedReader("ab", 1)
    @test fill_buffer(rdr) == 1
    @test fill_buffer(rdr) === nothing
    consume(rdr, 1)
    @test fill_buffer(rdr) == 1
    @test get_buffer(rdr) == b"b"

    # Generic functions
    rdr = BoundedReader("abc\ndef\r\nghi", 4)
    @test readline(rdr) == "abc"
    @test read(rdr, String) == "def\r\nghi"
    # Line longer than max buffer size
    @test_throws ArgumentError iterate(line_views(BoundedReader("abcdef\n", 4)))

    # Close
    rdr = BoundedReader("abc", 2)
    fill_buffer(rdr)
    close(rdr)
    @test isempty(get_buffer(rdr))
    @test_throws IOError fill_buffer(rdr)
    close(rdr)
end

@testset "BoundedWriter" begin
    @test_throws ArgumentError BoundedWriter(UInt8[], 0)

    sink = UInt8[]
    w = BoundedWriter(sink, 4)
    @test length(get_buffer(w)) == 4
    # Nothing to flush, so buffer can't grow
    @test grow_buffer(w) == 0
    @test length(get_buffer(w)) == 4

    copyto!(get_buffer(w), b"abc")
    @test_throws IOError consume(w, 5)
    @test_throws IOError consume(w, -1)
    consume(w, 3)
    @test length(get_buffer(w)) == 1
    @test isempty(sink)
    @test grow_buffer(w) == 3
    @test sink == b"abc"
    @test length(get_buffer(w)) == 4

    # Generic functions
    @test write(w, "Hello, world!") == 13
    flush(w)
    @test String(copy(sink)) == "abcHello, world!"

    # Close flushes
    write(w, 0x01)
    close(w)
    @test sink == b"abcHello, world!\x01"
    @test isempty(get_buffer(w))
    @test_throws IOError grow_buffer(w)
    close(w)
end
