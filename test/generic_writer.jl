@testset "write(::T, ::UInt8)" begin
    io = GenericBufWriter()

    # Write single bytes
    @test write(io, 0x48) == 1  # 'H'
    @test write(io, 0x69) == 1  # 'i'
    @test write(io, 0x21) == 1  # '!'

    # Check the data was written
    @test io.x.vec == [0x48, 0x69, 0x21]
    @test String(io.x.vec) == "Hi!"

    # Test writing to a writer that becomes full
    small_vec = UInt8[1, 2]  # Very small initial capacity
    io2 = GenericBufWriter(small_vec)
    # Fill remaining space and force growth
    for i in 1:10
        @test write(io2, UInt8(i + 2)) == 1
    end
    @test length(io2.x.vec) == 12
    @test io2.x.vec[1:2] == [1, 2]  # Original data preserved
    @test io2.x.vec[3:12] == [3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
end

@testset "write(::T, ::String)" begin
    io = GenericBufWriter()

    # Write basic string
    @test write(io, "hello") == 5
    @test String(copy(io.x.vec)) == "hello"

    # Write more strings
    @test write(io, " world") == 6
    @test String(copy(io.x.vec)) == "hello world"

    # Write empty string
    @test write(io, "") == 0
    @test String(copy(io.x.vec)) == "hello world"  # Unchanged

    # Write string with Unicode
    io2 = GenericBufWriter()
    unicode_str = "Hello 世界"
    n_written = write(io2, unicode_str)
    @test n_written == sizeof(unicode_str)
    @test String(io2.x.vec) == unicode_str

    # Write very long string to test buffer growth
    io3 = GenericBufWriter()
    long_str = "x"^1000
    @test write(io3, long_str) == 1000
    @test String(io3.x.vec) == long_str
end

@testset "write(::T, ::Array)" begin
    io = GenericBufWriter()

    # Write UInt8 array
    arr = UInt8[1, 2, 3, 4, 5]
    @test write(io, arr) == 5
    @test io.x.vec == arr

    # Write empty array
    io3 = GenericBufWriter()
    empty_arr = UInt8[]
    @test write(io3, empty_arr) == 0
    @test isempty(io3.x.vec)

    # Write large array
    io4 = GenericBufWriter()
    large_arr = UInt8[i % 256 for i in 1:1000]
    @test write(io4, large_arr) == 1000
    @test io4.x.vec == large_arr
end

@testset "write(::T, memory-backed inputs)" begin
    io = GenericBufWriter()
    string_codeunits = codeunits("abc")
    @test write(io, string_codeunits) == 3

    string = "_def_"
    substring_codeunits = codeunits(SubString(string, 2, 4))
    @test write(io, substring_codeunits) == 3

    data = UInt8[0x00, 0x67, 0x68, 0x69, 0x00]
    @test write(io, view(data, 2:4)) == 3

    bytes = ByteVector(undef, 3)
    copyto!(bytes, b"jkl")
    @test write(io, bytes) == 3

    @test io.x.vec == b"abcdefghijkl"

    allocation_writer = BoundedWriter(sizehint!(UInt8[], 1024), 32)
    write(allocation_writer, string_codeunits)
    write(allocation_writer, substring_codeunits)
    @test @allocated(write(allocation_writer, string_codeunits)) == 0
    @test @allocated(write(allocation_writer, substring_codeunits)) == 0
end

@testset "unsafe_write" begin
    # Test basic unsafe_write with array
    io = GenericBufWriter()
    arr = UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f]  # "Hello"
    n_written = unsafe_write(io, arr, UInt(5))
    @test n_written == 5
    @test String(io.x.vec) == "Hello"

    # Test with pointer directly
    io2 = GenericBufWriter()
    data = b"World!"
    GC.@preserve data begin
        ptr = pointer(data)
        n_written2 = unsafe_write(io2, ptr, UInt(6))
        @test n_written2 == 6
        @test String(io2.x.vec) == "World!"
    end

    # Test writing zero bytes
    io3 = GenericBufWriter()
    n_written3 = unsafe_write(io3, UInt8[], UInt(0))
    @test n_written3 == 0
    @test isempty(io3.x.vec)

    # Test writing partial array
    io4 = GenericBufWriter()
    arr4 = collect(b"abcdefgh")
    n_written4 = unsafe_write(io4, arr4, UInt(4))
    @test n_written4 == 4
    @test String(io4.x.vec) == "abcd"

    # Writing from a `Ref` of any type
    x = 0x0102030405060708
    expected = reinterpret(UInt8, [x])
    io5 = GenericBufWriter()
    @test unsafe_write(io5, Ref(x), UInt(8)) == 8
    @test io5.x.vec == expected

    # The writer's buffer is too short to hold the value, so it is written in chunks
    sink = UInt8[]
    io6 = BoundedWriter(sink, 3)
    @test unsafe_write(io6, Ref(x), UInt(8)) == 8
    flush(io6)
    @test sink == expected

    # `nbytes` can be any non-negative `Integer`
    io5 = GenericBufWriter()
    @test unsafe_write(io5, Ref(x), Int32(8)) == 8
    @test io5.x.vec == expected
    @test_throws InexactError unsafe_write(io5, Ref(x), -1)

    io7 = GenericBufWriter()
    @test unsafe_write(io7, Ref((0x61, 0x62, 0x63)), UInt(3)) == 3
    @test io7.x.vec == b"abc"

    # Only the first `nbytes` bytes are written
    io8 = GenericBufWriter()
    @test unsafe_write(io8, Ref(x), UInt(2)) == 2
    @test io8.x.vec == expected[1:2]

    # Refs of non-bitstypes would write e.g. a string's length or a vector's pointer
    @test_throws ArgumentError unsafe_write(GenericBufWriter(), Ref("hello"), UInt(5))
    @test_throws ArgumentError unsafe_write(GenericBufWriter(), Ref([0x61, 0x62]), UInt(2))
    @test_throws ArgumentError unsafe_write(GenericBufWriter(), Ref{Any}(x), UInt(8))

    # A `Ptr{T}` is a `Ref{T}`, but may point to more than `sizeof(T)` bytes
    floats = [1.0, 2.0]
    io9 = GenericBufWriter()
    @test GC.@preserve(floats, unsafe_write(io9, pointer(floats), UInt(16))) == 16
    @test io9.x.vec == reinterpret(UInt8, floats)

    # Writer cannot make room for all bytes
    err = try
        unsafe_write(FixedWriter(3), Ref(x), UInt(8))
    catch e
        e
    end
    @test err isa IOError
    @test err.kind == IOErrorKinds.WriterFull
end

write_uint64_from_ref(io::AbstractBufWriter, x::UInt64) = unsafe_write(io, Ref(x), UInt(8))

@testset "unsafe_write from Ref does not allocate" begin
    # Every write takes the slow path, since the buffer holds at most 3 bytes
    io = BoundedWriter(sizehint!(UInt8[], 1024), 3)
    write_uint64_from_ref(io, UInt64(1))
    @test @allocated(write_uint64_from_ref(io, UInt64(2))) == 0
end

@testset "get_nonempty_buffer(::T, ::Int)" begin
    # Buffer already long enough
    sink = UInt8[]
    io = BoundedWriter(sink, 4)
    @test length(get_nonempty_buffer(io, 3)) ≥ 3
    @test length(get_nonempty_buffer(io, 4)) == 4
    @test isempty(sink)

    # Buffer can never hold 5 bytes
    @test get_nonempty_buffer(io, 5) === nothing
    @test isempty(sink)

    # Buffer must be flushed to hold 3 bytes
    write(io, "ab")
    buffer = get_nonempty_buffer(io, 3)
    @test length(buffer) ≥ 3
    @test sink == b"ab"

    # Flushes, but then returns nothing
    write(io, "cd")
    @test get_nonempty_buffer(io, 5) === nothing
    @test sink == b"abcd"

    # Nonpositive min_size still returns a nonempty buffer when full
    for min_size in (0, -5)
        sink = UInt8[]
        io = BoundedWriter(sink, 3)
        write(io, "abc")
        @test !isempty(get_nonempty_buffer(io, min_size))
        @test sink == b"abc"
    end

    # Full writer
    io = FixedWriter(3)
    @test length(get_nonempty_buffer(io, 2)) == 3
    @test get_nonempty_buffer(io, 4) === nothing
    write(io, "abc")
    @test get_nonempty_buffer(io, 1) === nothing
    @test get_nonempty_buffer(io, 0) === nothing

    # Growable writer, which only implements the required methods
    io = GenericBufWriter(collect(b"abc"))
    buffer = get_nonempty_buffer(io, 1000)
    @test length(buffer) ≥ 1000
    copyto!(buffer, b"def")
    consume(io, 3)
    @test io.x.vec == b"abcdef"

    # Closed writer
    io = BoundedWriter(UInt8[], 3)
    close(io)
    err = try
        get_nonempty_buffer(io, 1)
    catch e
        e
    end
    @test err isa IOError
    @test err.kind == IOErrorKinds.ClosedIO
end

@testset "print(::T, ::SubString)" begin
    io = GenericBufWriter()

    str = "Hello World"
    substr = SubString(str, 1, 5)  # "Hello"
    print(io, substr)
    @test String(copy(io.x.vec)) == "Hello"

    substr2 = SubString(str, 7, 11)  # "World"
    print(io, substr2)
    @test String(copy(io.x.vec)) == "HelloWorld"
end

@testset "print and println" begin
    io = GenericBufWriter()

    # Non-string arguments print as they would to an IO, without quotes
    @test print(io, 1) === nothing
    @test print(io, 'a') === nothing
    @test print(io, :sym) === nothing
    @test print(io, "ab"[1:1]) === nothing
    @test print(io, SubString("xyz", 2:3)) === nothing
    @test print(io, lazy"q$(2)") === nothing
    @test print(io, nothing) === nothing
    @test print(io, [1, 2]) === nothing
    @test String(copy(io.x.vec)) == "1asymayzq2nothing[1, 2]"

    # Varargs forms must not fall through to Base's `print(xs...)`,
    # which would print to stdout
    io = GenericBufWriter()
    @test print(io) === nothing
    @test print(io, "a", 'b', 3) === nothing
    @test println(io) === nothing
    @test println(io, "x") === nothing
    @test println(io, "y", 'z', 1.5) === nothing
    @test String(copy(io.x.vec)) == "ab3\nx\nyz1.5\n"

    # Printing to a writer that must flush to make room
    sink = UInt8[]
    io = BoundedWriter(sink, 2)
    println(io, "Hello, ", "world", '!', 42)
    flush(io)
    @test String(copy(sink)) == "Hello, world!42\n"
end

@testset "Complex write scenarios" begin
    # Test mixed writes that cause buffer growth
    io = GenericBufWriter(UInt8[1, 2])  # Start small

    write(io, "Hello ")             # String
    write(io, UInt8[0x41, 0x42])    # Array
    write(io, 0xFF)                 # Single byte

    expected = [
        1, 2,                           # Original data
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20,  # "Hello "
        0x41, 0x42,                     # Array
        0xFF,                            # Single byte
    ]
    @test io.x.vec == expected
end

@testset "write_repeated" begin
    sink = UInt8[]
    io = BoundedWriter(sink, 10)
    @test write_repeated(io, UInt8('y'), 33) === 33
    flush(io)
    @test String(sink) == 'y'^33

    io = GenericBufWriter()
    @test write_repeated(io, UInt8(33), 0) === 0
    @test isempty(takestring!(io.x))
    @test write_repeated(io, UInt8(0x03), 8) === 8
    @test takestring!(io.x) == '\3'^8
end

@testset "Full writer" begin
    io = FixedWriter(3)
    @test write(io, "ab") == 2
    @test write(io, 0x63) == 1
    err = try
        write(io, 0x64)
    catch e
        e
    end
    @test err isa IOError
    @test err.kind == IOErrorKinds.WriterFull

    io = FixedWriter(3)
    err = try
        write(io, "abcd")
    catch e
        e
    end
    @test err isa IOError
    @test err.kind == IOErrorKinds.WriterFull

    io = FixedWriter(3)
    err = try
        write_repeated(io, 0x61, 4)
    catch e
        e
    end
    @test err isa IOError
    @test err.kind == IOErrorKinds.WriterFull
    @test write_repeated(FixedWriter(3), 0x61, 3) === 3
end

@testset "close and isopen" begin
    # Each writer, and whether closing makes it unusable
    writers = [
        (() -> BufWriter(IOBuffer()), true),
        (() -> BoundedWriter(UInt8[], 4), true),
        (() -> VecWriter(), false),
        (() -> GenericBufWriter(), false),
        (() -> FixedWriter(4), false),
    ]
    for (make, closing_disables) in writers
        writer = make()
        @test isopen(writer)
        @test close(writer) === nothing
        @test isopen(writer) == !closing_disables
        # Closing is idempotent
        @test close(writer) === nothing
        @test isopen(writer) == !closing_disables
    end

    # Closing flushes first
    sink = UInt8[]
    writer = BoundedWriter(sink, 4)
    write(writer, "ab")
    @test isempty(sink)
    close(writer)
    @test sink == b"ab"
end
