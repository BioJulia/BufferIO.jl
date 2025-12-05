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

@testset "write(::T, x, xs...)" begin
    io = GenericBufWriter()

    # Write multiple items
    n_written = write(io, 0x41, 0x42, 0x43)  # 'A', 'B', 'C'
    @test n_written == 3
    @test String(io.x.vec) == "ABC"

    # Write mixed types
    io2 = GenericBufWriter()
    n_written2 = write(io2, "Hello", 0x20, "World")  # "Hello" + space + "World"
    @test n_written2 == 11  # 5 + 1 + 5
    @test String(io2.x.vec) == "Hello World"

    # Write single item (should work same as direct write)
    io3 = GenericBufWriter()
    @test write(io3, 0xFF) == 1
    @test io3.x.vec == [0xFF]

    # Write empty sequence
    io4 = GenericBufWriter()
    @test_throws MethodError write(io4) == 0  # No arguments
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

@testset "write(::T, ::PlainTypes)" begin
    # Test Int8
    io = GenericBufWriter()
    @test write(io, Int8(-42)) == 1
    @test io.x.vec[1] == reinterpret(UInt8, Int8(-42))

    # Test UInt16
    io2 = GenericBufWriter()
    @test write(io2, htol(UInt16(0x1234))) == 2
    # Should be little endian
    @test io2.x.vec == [0x34, 0x12]

    # Test Int32
    io3 = GenericBufWriter()
    @test write(io3, htol(Int32(0x12345678))) == 4
    @test io3.x.vec == [0x78, 0x56, 0x34, 0x12]  # Little endian

    # Test UInt64
    io4 = GenericBufWriter()
    @test write(io4, htol(UInt64(0x123456789ABCDEF0))) == 8
    @test io4.x.vec == [0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12]

    # Test Float32
    io5 = GenericBufWriter()
    @test write(io5, Float32(1.0)) == 4
    @test reinterpret(Float32, io5.x.vec)[1] == Float32(1.0)

    # Test Float64
    io6 = GenericBufWriter()
    @test write(io6, Float64(3.14159)) == 8
    @test reinterpret(Float64, io6.x.vec)[1] == Float64(3.14159)

    # Test Bool
    io7 = GenericBufWriter()
    @test write(io7, true) == 1
    @test write(io7, false) == 1
    @test io7.x.vec == [0x01, 0x00]

    # Test Int128
    io8 = GenericBufWriter()
    big_val = Int128(0x123456789ABCDEF0) << 64 | Int128(0xFEDCBA9876543210)
    @test write(io8, big_val) == 16
    @test length(io8.x.vec) == 16
    @test reinterpret(Int128, io8.x.vec)[1] == big_val

    # With smaller buffer size
    io = GenericBufWriter(zeros(UInt8, 0))
    sizehint!(io.x.vec, 2)
    write(io, 3137397676310531179717)
    @test only(reinterpret(Int128, io.x.vec)) == 3137397676310531179717
end

@testset "write(::T, ::Array)" begin
    io = GenericBufWriter()

    # Write UInt8 array
    arr = UInt8[1, 2, 3, 4, 5]
    @test write(io, arr) == 5
    @test io.x.vec == arr

    # Write different array types that become UInt8 arrays
    io2 = GenericBufWriter()
    int_arr = [0x41, 0x42, 0x43]  # Will be treated as UInt8
    @test write(io2, int_arr) == 3
    @test String(io2.x.vec) == "ABC"

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

    # Write various types
    write(io, "Hello ")         # String
    write(io, UInt32(0x12345678)) # 4-byte integer
    write(io, [0x41, 0x42])     # Array
    write(io, 0xFF)             # Single byte

    expected = [
        1, 2,                           # Original data
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20,  # "Hello "
        0x78, 0x56, 0x34, 0x12,         # UInt32 little endian
        0x41, 0x42,                     # Array
        0xFF,                            # Single byte
    ]
    @test io.x.vec == expected
end

@testset "Write to bounded buffer" begin
    for (n, n_bytes) in Any[
            (-32432.1234, 3),
            (1.1f3, 2),
            (Int32(394398243), 1),
            (Int8(2), 1),
            (Int128(94837923794837492), 6),
            (Int16(-12324), 1),
        ]
        w = BoundedWriter(n_bytes)
        write(w, n)
        flush(w)
        @test only(reinterpret(typeof(n), w.x.vec)) === n
    end
end

@testset "Write char" begin
    io = GenericBufWriter()
    @test write(io, '\0') == 1
    @test write(io, 'P') == 1
    @test write(io, '\x7f') == 1
    @test write(io, 'æ') == 2
    @test write(io, '😁') == 4
    @test io.x.vec == b"\0P\x7fæ😁"
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
