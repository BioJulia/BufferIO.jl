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
    io = BoundedWriter(10)
    @test write_repeated(io, UInt8('y'), 33) === 33
    flush(io)
    @test takestring!(io.x) == 'y'^33

    io = GenericBufWriter()
    @test write_repeated(io, UInt8(33), 0) === 0
    @test isempty(takestring!(io.x))
    @test write_repeated(io, UInt8(0x03), 8) === 8
    @test takestring!(io.x) == '\3'^8
end
