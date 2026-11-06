# Records the writes and flushes it receives, in order, to show when `LineWriter` flushes.
mutable struct RecordingIO <: IO
    events::Vector{Any}
    is_open::Bool
end

RecordingIO() = RecordingIO([], true)

function Base.unsafe_write(io::RecordingIO, ptr::Ptr{UInt8}, n::UInt)
    push!(io.events, unsafe_string(ptr, n))
    return Int(n)
end

Base.flush(io::RecordingIO) = (push!(io.events, :flush); nothing)

function Base.close(io::RecordingIO)
    push!(io.events, :close)
    io.is_open = false
    return nothing
end

Base.isopen(io::RecordingIO) = io.is_open

# The bytes which reached `io`, ignoring how they were split up
written(io::RecordingIO) = join(filter(e -> e isa String, io.events))

function recording_writer(buffer_size::Int = 4096)
    io = RecordingIO()
    return (io, LineWriter(BufWriter(io, buffer_size)))
end

unflushed(w::LineWriter) = String(get_unflushed(w.inner))

@testset "LineWriter construction" begin
    inner = BufWriter(IOBuffer())
    writer = LineWriter(inner)
    @test writer isa LineWriter{BufWriter{IOBuffer}}
    @test writer isa IO
    @test writer.inner === inner

    @test LineWriter(VecWriter()) isa LineWriter{VecWriter}
    @test_throws MethodError LineWriter(IOBuffer())
end

@testset "LineWriter flushes through the last newline" begin
    for (input, events, tail) in [
            ("", [], ""),
            ("abc", [], "abc"),
            ("\n", ["\n", :flush], ""),
            ("abc\n", ["abc\n", :flush], ""),
            ("\nabc", ["\n", :flush], "abc"),
            ("a\nb", ["a\n", :flush], "b"),
            ("a\nb\nc", ["a\nb\n", :flush], "c"),
            ("a\n\n", ["a\n\n", :flush], ""),
            ("a\rb", [], "a\rb"),
        ]
        (io, writer) = recording_writer()
        @test write(writer, input) == sizeof(input)
        @test io.events == events
        @test unflushed(writer) == tail
    end

    # Buffered bytes from previous writes go out with the line that completes them
    (io, writer) = recording_writer()
    write(writer, "ab")
    write(writer, "c\nd")
    write(writer, "e\n")
    @test io.events == ["abc\n", :flush, "de\n", :flush]
    @test isempty(unflushed(writer))
end

@testset "LineWriter with writes longer than the buffer" begin
    # Without a newline, the inner writer flushes when full, but only to its own IO
    (io, writer) = recording_writer(4)
    write(writer, "a"^20)
    @test written(io) * unflushed(writer) == "a"^20
    @test :flush ∉ io.events

    (io, writer) = recording_writer(4)
    input = "abcdefg\nhijklmnop\nqr"
    @test write(writer, input) == sizeof(input)
    @test written(io) == "abcdefg\nhijklmnop\n"
    @test last(io.events) === :flush
    @test unflushed(writer) == "qr"

    # The tail is itself longer than the buffer
    (io, writer) = recording_writer(4)
    write(writer, "a\n" * "b"^10)
    @test written(io) * unflushed(writer) == "a\n" * "b"^10
    @test count(==(:flush), io.events) == 1
end

@testset "LineWriter byte and char writes" begin
    (io, writer) = recording_writer()
    @test write(writer, UInt8('a')) === 1
    @test isempty(io.events)
    @test write(writer, 0x0a) === 1
    @test io.events == ["a\n", :flush]

    (io, writer) = recording_writer()
    @test write(writer, 'é') == 2
    @test isempty(io.events)
    @test write(writer, '\n') == 1
    @test io.events == ["é\n", :flush]
end

@testset "LineWriter argument types" begin
    bytes = collect(b"a\nb")
    padded = collect(b"xa\nby")
    strided = collect(b"a.\n.b")
    # In column-major order, the first column is "a\n", and the second is "bc"
    matrix = reshape(collect(b"a\nbc"), 2, 2)

    for (value, tail) in [
            ("a\nb", "b"),
            (SubString("xa\nby", 2, 4), "b"),
            (Test.GenericString("a\nb"), "b"),
            (Base.AnnotatedString("a\nb"), "b"),
            (SubString(Base.AnnotatedString("xa\nby"), 2, 4), "b"),
            (bytes, "b"),
            (Memory{UInt8}(bytes), "b"),
            (MemoryView(bytes), "b"),
            (ImmutableMemoryView(bytes), "b"),
            (codeunits("a\nb"), "b"),
            (codeunits(Test.GenericString("a\nb")), "b"),
            (view(padded, 2:4), "b"),
            (view(codeunits("xa\nby"), 2:4), "b"),
            (view(strided, 1:2:5), "b"),
            (matrix, "bc"),
            (view(matrix, :, 1:2), "bc"),
        ]
        (io, writer) = recording_writer()
        @test write(writer, value) == 2 + length(tail)
        @test written(io) == "a\n"
        @test last(io.events) === :flush
        @test unflushed(writer) == tail
    end

    # Added in Julia 1.14
    if isdefined(Base, :StringView)
        for value in (Base.StringView(bytes), SubString(Base.StringView(padded), 2, 4))
            (io, writer) = recording_writer()
            @test write(writer, value) == 3
            @test io.events == ["a\n", :flush]
            @test unflushed(writer) == "b"
        end
    end

    # Strings are written in one go, not char by char, which would flush at every newline
    (io, writer) = recording_writer()
    @test write(writer, Test.GenericString("a\nb\nc")) == 5
    @test io.events == ["a\nb\n", :flush]
    @test unflushed(writer) == "c"

    # 0x0a counts as a newline, even in binary data
    (io, writer) = recording_writer()
    @test write(writer, htol(UInt32(0x0a))) == 4
    @test written(io) == "\n"
    @test get_unflushed(writer.inner) == [0x00, 0x00, 0x00]

    (io, writer) = recording_writer()
    @test write(writer, Ref(0x0a)) == 1
    @test io.events == ["\n", :flush]

    (io, writer) = recording_writer()
    @test write(writer, "a\n", "b") == 3
    @test written(io) == "a\n"

    for n in (UInt(3), 3, Int32(3))
        (io, writer) = recording_writer()
        s = "a\nb"
        @test GC.@preserve(s, unsafe_write(writer, pointer(s), n)) === 3
        @test io.events == ["a\n", :flush]
        @test unflushed(writer) == "b"
    end
end

@testset "LineWriter with print and show" begin
    (io, writer) = recording_writer()
    print(writer, "a\nb")
    @test io.events == ["a\n", :flush]
    @test unflushed(writer) == "b"

    (io, writer) = recording_writer()
    print(writer, 1)
    @test isempty(io.events)
    print(writer, '\n')
    @test io.events == ["1\n", :flush]

    (io, writer) = recording_writer()
    println(writer, 1)
    @test io.events == ["1\n", :flush]

    (io, writer) = recording_writer()
    println(writer, "a", 2)
    @test io.events == ["a2\n", :flush]

    (io, writer) = recording_writer()
    show(writer, MIME"text/plain"(), [1 2; 3 4])
    @test written(io) * unflushed(writer) == sprint(show, MIME"text/plain"(), [1 2; 3 4])
    @test last(io.events) === :flush

    (io, writer) = recording_writer()
    print(IOContext(writer, :compact => true), 1.5, "\n")
    @test io.events == ["1.5\n", :flush]

    (io, writer) = recording_writer()
    printstyled(writer, "a\n"; color = :red)
    @test written(io) == "a\n"
    @test last(io.events) === :flush

    (io, writer) = recording_writer()
    print(writer, Base.AnnotatedString("a\nb"))
    @test written(io) == "a\n"
    @test unflushed(writer) == "b"
end

@testset "LineWriter as an IO" begin
    (io, writer) = recording_writer()
    write(writer, IOBuffer("a\nb"))
    @test written(io) == "a\n"
    @test unflushed(writer) == "b"

    (io, writer) = recording_writer()
    copyline(writer, CursorReader("a\nb"); keep = true)
    @test io.events == ["a\n", :flush]
end

@testset "LineWriter wrapping other writers" begin
    # A writer with no underlying IO
    vec_writer = VecWriter()
    writer = LineWriter(vec_writer)
    @test write(writer, "a\nb") == 3
    @test String(vec_writer.vec) == "a\nb"

    generic_writer = GenericBufWriter()
    writer = LineWriter(generic_writer)
    @test write(writer, "a\nb") == 3
    @test write(writer, 0x0a) == 1
    @test String(generic_writer.x.vec) == "a\nb\n"

    # Implements only the required methods. Its flush moves all bytes to the sink.
    sink = UInt8[]
    bounded = BoundedWriter(sink, 4)
    writer = LineWriter(bounded)
    @test write(writer, "abcdef\ngh") == 9
    @test String(copy(sink)) == "abcdef\n"
    flush(writer)
    @test String(copy(sink)) == "abcdef\ngh"

    # Can't make room for all the bytes
    writer = LineWriter(FixedWriter(4))
    @test write(writer, "ab\n") == 3
    err = @test_throws IOError write(writer, "cd")
    @test err.value.kind == IOErrorKinds.WriterFull
end

@testset "LineWriter forwarded methods" begin
    (io, writer) = recording_writer()
    @test isopen(writer)
    write(writer, "a")
    @test flush(writer) === nothing
    @test io.events == ["a", :flush]

    (io, writer) = recording_writer()
    write(writer, "a\nb")
    @test close(writer) === nothing
    @test !isopen(writer)
    @test !isopen(writer.inner)
    @test written(io) == "a\nb"
    @test last(io.events) === :close
    close(writer) # closing twice does nothing
    @test count(==(:close), io.events) == 1

    err = @test_throws IOError write(writer, "a\n")
    @test err.value.kind == IOErrorKinds.ClosedIO
    err = @test_throws IOError write(writer, 0x0a)
    @test err.value.kind == IOErrorKinds.ClosedIO
end

@testset "LineWriter seeking" begin
    buffer = IOBuffer()
    writer = LineWriter(BufWriter(buffer))
    write(writer, "abc\ndef")
    @test position(writer) == 7
    @test filesize(writer) == 7

    # These return `writer`, not its inner writer, since writes to the inner writer
    # would no longer be line-flushed
    @test seek(writer, 2) === writer
    @test position(writer) == 2
    @test seek(writer, Int32(1)) === writer
    @test position(writer) == 1
    @test seekstart(writer) === writer
    @test position(writer) == 0
    @test seekend(writer) === writer
    @test position(writer) == 7

    seek(writer, 1)
    write(writer, "xy\n")
    @test String(take!(copy(buffer))) == "axy\ndef"
    @test filesize(writer) == 7

    err = @test_throws IOError seek(writer, 8)
    @test err.value.kind == IOErrorKinds.BadSeek

    # Not supported by the inner writer
    @test_throws MethodError seek(LineWriter(BoundedWriter(UInt8[], 4)), 0)
end

@testset "LineWriter does not own its inner writer" begin
    (io, writer) = recording_writer()

    # Writes bypassing `writer` are not line-flushed...
    write(writer.inner, "a\n")
    @test isempty(io.events)

    # ... but nothing is lost, and they keep their order
    write(writer, "b\n")
    @test io.events == ["a\nb\n", :flush]

    flush(writer.inner)
    write(writer.inner, "c")
    close(writer.inner)
    @test !isopen(writer)
    @test written(io) == "a\nb\nc"
end

@testset "LineWriter with failing IO" begin
    # The error reaches the caller, and the bytes stay in the inner writer, like with
    # `BufWriter`. Bytes after the newline have not been written yet.
    writer = LineWriter(BufWriter(FailingWriteIO(false), 16))
    @test_throws ErrorException write(writer, "a\nb")
    @test unflushed(writer) == "a\n"

    writer = LineWriter(BufWriter(FailingWriteIO(false), 16))
    write(writer, UInt8('a'))
    @test_throws ErrorException write(writer, 0x0a)
    @test unflushed(writer) == "a\n"

    # Without a newline, nothing reaches the failing IO
    writer = LineWriter(BufWriter(FailingWriteIO(false), 16))
    @test write(writer, "abc") == 3
    @test unflushed(writer) == "abc"
end

@testset "LineWriter has no method ambiguities" begin
    ambiguities = filter(Test.detect_ambiguities(BufferIO, Base; recursive = false)) do (a, b)
        occursin("LineWriter", string(a.sig)) || occursin("LineWriter", string(b.sig))
    end
    @test isempty(ambiguities)
end
