@testset "ByteVector specifics" begin
    v = ByteVector(undef, 10)
    @test length(v) == 10
    push!(v, 0x0a)
    @test length(v) == 11
    @test v[11] == 0x0a

    copy!(v, b"abcdefghijk")
    @test v == b"abcdefghijk"
    resize!(v, 6)
    @test v == b"abcdef"
    vmem = BufferIO.get_memory(v)
    resize!(v, 11)
    @test length(v) == 11
    @test BufferIO.get_memory(v) === vmem
    resize!(v, 100)
    @test length(v) == 100
    @test BufferIO.get_memory(v) !== vmem

    @test_throws ArgumentError resize!(v, -1)
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
    close(vw)
    flush(vw)

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

@testset "Nonzero offset" begin
    v = UInt8[0x01, 0x02]
    pushfirst!(v, 0xff)
    vw = VecWriter(v)
    @test get_unflushed(vw) == [0xff, 0x01, 0x02]
end
