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

    # The two-arg method never returns `nothing`, and the compiler knows it
    @test (@inferred get_nonempty_buffer(VecWriter(), 100)) isa MutableMemoryView{UInt8}

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

@testset "Memory is string-owned when starting with empty memory" begin
    function test_reuses_memory(vw::VecWriter, expected::String)
        p = pointer(vw.vec)
        s = takestring!(vw)
        @test s == expected
        return @test pointer(s) == p
    end
    writes = [
        vw -> write(vw, 0x61),
        vw -> write(vw, "a"),
        vw -> write(vw, "a"^100),
        vw -> (buf = get_nonempty_buffer(vw); buf[1] = 0x61; consume(vw, 1)),
        vw -> (grow_buffer(vw); buf = get_buffer(vw); buf[1] = 0x61; consume(vw, 1)),
    ]
    for f in writes, make in [VecWriter, () -> VecWriter(undef, 0), () -> VecWriter(UInt8[])]
        vw = make()
        f(vw)
        expected = String(copy(vw.vec))
        test_reuses_memory(vw, expected)
        # After takestring!, the vector has empty memory again
        f(vw)
        test_reuses_memory(vw, expected)
    end

    # Growing far beyond the initial size
    vw = VecWriter()
    for i in 1:1000
        write(vw, i % UInt8)
    end
    test_reuses_memory(vw, String([i % UInt8 for i in 1:1000]))
end

@testset "take!" begin
    # Basic use: Returns the written bytes, and leaves the writer empty
    io = VecWriter()
    write(io, "Hello, world!")
    v = take!(io)
    @test v isa MutableMemoryView{UInt8}
    @test v == b"Hello, world!"
    @test isempty(io.vec)
    @test isempty(get_unflushed(io))

    # The bytes are not copied
    io = VecWriter()
    write(io, "abc")
    p = pointer(io.vec)
    v = take!(io)
    @test pointer(v) == p

    # Writes after take! do not affect the result, whether or not the writes
    # would fit in the memory of the taken bytes
    for s in ["xyz", "x"^1000]
        io = VecWriter(undef, 100)
        write(io, "abc")
        v = take!(io)
        write(io, s)
        @test v == b"abc"
        @test io.vec == codeunits(s)
        # Neither do other mutations of the vector
        fill!(io.vec, 0x00)
        empty!(io.vec)
        append!(io.vec, b"def")
        @test v == b"abc"
    end

    # The writer is usable after take!, and memory is still string-owned
    io = VecWriter()
    write(io, "abc")
    take!(io)
    write(io, "def")
    p = pointer(io.vec)
    s = takestring!(io)
    @test s == "def"
    @test pointer(s) == p

    # Repeated take!
    io = VecWriter()
    results = map(["a", "bc", "", "def"]) do s
        write(io, s)
        take!(io)
    end
    @test results == [b"a", b"bc", b"", b"def"]

    # Empty writers
    for io in [VecWriter(), VecWriter(undef, 0), VecWriter(undef, 100)]
        v = take!(io)
        @test isempty(v)
        @test isempty(io.vec)
        write(io, "abc")
        @test isempty(v)
        @test io.vec == b"abc"
    end

    # Takes from a wrapped vector, including bytes not written by the writer,
    # and with a nonzero offset into its memory
    vec = collect(b"_abc")
    popfirst!(vec)
    io = VecWriter(vec)
    write(io, "def")
    v = take!(io)
    @test v == b"abcdef"
    @test isempty(vec)
    push!(vec, 0x01)
    @test v == b"abcdef"
    @test io.vec === vec
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
