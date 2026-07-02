@testset "ByteVector" begin
    @test ByteVector === Vector{UInt8}
end

@testset "Wraps vector" begin
    v = collect(b"abc")
    vw = VecWriter(v)
    @test vw.vec === v
    write(vw, "def")
    @test v == b"abcdef"

    # Interleave mutations of the vector with writes
    push!(v, UInt8('g'))
    write(vw, "hi")
    pushfirst!(v, UInt8('_'))
    write(vw, 0x6a)
    popfirst!(v)
    popfirst!(v)
    write(vw, "kl")
    sizehint!(v, length(v); shrink = true)
    write(vw, "m")
    @test v == b"bcdefghijklm"
    @test get_unflushed(vw) == v
end

@testset "Nonzero offset" begin
    v = UInt8[0x01, 0x02]
    pushfirst!(v, 0xff)
    vw = VecWriter(v)
    @test get_unflushed(vw) == [0xff, 0x01, 0x02]

    # Element offset far into the memory
    v = collect(UInt8, 1:100)
    for _ in 1:90
        popfirst!(v)
    end
    vw = VecWriter(v)
    buffer = get_nonempty_buffer(vw, 50)
    @test length(buffer) ≥ 50
    fill!(buffer, 0xaa)
    consume(vw, 50)
    @test v == [collect(UInt8, 91:100); fill(0xaa, 50)]
end

@testset "Buffer growth" begin
    vw = VecWriter(UInt8[])
    for _ in 1:10
        len = length(get_buffer(vw))
        n_grown = grow_buffer(vw)
        @test n_grown > 0
        @test length(get_buffer(vw)) == len + n_grown
        write(vw, UInt8(len % UInt8))
    end

    for min_size in [0, 1, 5, 100, 10_000]
        vw = VecWriter()
        @test length(get_nonempty_buffer(vw, min_size)) ≥ max(1, min_size)
    end

    # Growing with a far offset moves the elements back to the start of the memory
    v = collect(UInt8, 1:100)
    for _ in 1:90
        popfirst!(v)
    end
    vw = VecWriter(v)
    len = length(get_buffer(vw))
    n_grown = grow_buffer(vw)
    @test n_grown > 0
    @test length(get_buffer(vw)) == len + n_grown
    @test v == 91:100
end

@testset "Consume" begin
    vw = VecWriter()
    n = length(get_buffer(vw))
    @test_throws IOError consume(vw, -1)
    @test_throws IOError consume(vw, n + 1)
    consume(vw, n)
    @test length(vw.vec) == n
    @test isempty(get_buffer(vw))
end

@testset "takestring!" begin
    v = collect(b"abc")
    @test takestring!(v) == "abc"
    @test isempty(v)

    # The memory of the vector is reused by the string
    vw = VecWriter()
    write(vw, "abcdef")
    p = pointer(vw.vec)
    s = takestring!(vw)
    @test s == "abcdef"
    @test pointer(s) == p
    @test isempty(vw.vec)
    write(vw, "ghi")
    @test takestring!(vw) == "ghi"
end

@testset "Construction" begin
    vw = VecWriter()
    @test vw isa VecWriter
    vw = VecWriter([0x01, 0x02])
    @test vw isa VecWriter

    @test_throws MethodError VecWriter(UInt16[])
end

@testset "Basic methods" begin
    vw = VecWriter([0x61, 0x62, 0x63])
    @test get_unflushed(vw) == b"abc"

    # These do nothing
    @test isopen(vw)
    close(vw)
    flush(vw)
    @test isopen(vw)

    write(vw, 0x02)
    write(vw, 0x01)
    @test get_unflushed(vw) == b"abc\2\1"

    # Test overallocation
    @test !isempty(get_buffer(vw))

    data = get_buffer(vw)
    fill!(get_buffer(vw), 0xaa)
    consume(vw, length(data))
    written = get_unflushed(vw)
    @test written[1:5] == b"abc\2\1"
    @test all(==(0xaa), written[6:end])

    nonempty = get_nonempty_buffer(vw)
    @test !isempty(nonempty)

    # Remove vector content
    s = takestring!(vw.vec)
    @test isempty(vw.vec)
    @test isempty(get_buffer(vw))
    @test isempty(get_unflushed(vw))

    vw = VecWriter(collect(b"abcde"))
    @test takestring!(vw) == "abcde"
    @test isempty(vw.vec)
end

@testset "specialized methods" begin
    io = VecWriter()
    @test isempty(get_unflushed(io))
    @test write(io, 0xaa) == 1
    @test write(io, 0x61) == 1
    @test write(io, 0x63) == 1
    @test String(io.vec) == "\xaaac"
end
