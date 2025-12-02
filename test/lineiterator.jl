@testset "line_views basic functionality" begin
    # Test basic line iteration
    io = GenericBufReader("line1\nline2\nline3")
    iter = line_views(io)

    # Test iterator properties
    @test eltype(iter) == ImmutableMemoryView{UInt8}
    @test Base.IteratorSize(typeof(iter)) == Base.SizeUnknown()

    # Collect all lines
    lines = collect(iter)
    @test lines isa Vector{ImmutableMemoryView{UInt8}}
    @test length(lines) == 3
    @test String(lines[1]) == "line1"
    @test String(lines[2]) == "line2"
    @test String(lines[3]) == "line3"
end

@testset "line_views with chomp=true (default)" begin
    # Test default chomping behavior
    io = GenericBufReader("hello\nworld\n")
    lines = collect(line_views(io))
    @test length(lines) == 2
    @test String(lines[1]) == "hello"
    @test String(lines[2]) == "world"

    # Test with \r\n endings
    io2 = GenericBufReader("line1\r\nline2\r\n")
    lines2 = collect(line_views(io2; chomp = true))
    @test length(lines2) == 2
    @test String(lines2[1]) == "line1"
    @test String(lines2[2]) == "line2"

    # Test mixed line endings
    io3 = GenericBufReader("unix\nmac\rdos\r\nend")
    lines3 = collect(line_views(io3; chomp = true))
    @test length(lines3) == 3
    @test String(lines3[1]) == "unix"
    @test String(lines3[2]) == "mac\rdos"  # \r alone doesn't end line
    @test String(lines3[3]) == "end"
end

@testset "line_views edge cases" begin
    # Empty input
    empty_io = GenericBufReader("")
    empty_lines = collect(line_views(empty_io))
    @test isempty(empty_lines)

    # Single line without newline
    io1 = GenericBufReader("single line")
    lines1 = collect(line_views(io1))
    @test length(lines1) == 1
    @test String(lines1[1]) == "single line"

    # Only newlines
    io2 = GenericBufReader("\n\n\n")
    lines2 = collect(line_views(io2))
    @test length(lines2) == 3
    @test all(line -> String(line) == "", lines2)

    # Empty lines between content
    io3 = GenericBufReader("a\n\nb\n\nc")
    lines3 = collect(line_views(io3))
    @test length(lines3) == 5
    @test String(lines3[1]) == "a"
    @test String(lines3[2]) == ""
    @test String(lines3[3]) == "b"
    @test String(lines3[4]) == ""
    @test String(lines3[5]) == "c"

    # Single newline
    io4 = GenericBufReader("\n")
    lines4 = collect(line_views(io4))
    @test length(lines4) == 1
    @test String(lines4[1]) == ""

    # Bounded buffer size
    # Normal case - works
    rdr = BoundedReader("abcd\nefg\r\n", 5)
    it = line_views(rdr; chomp = false)
    @test first(iterate(it)) == b"abcd\n"

    # Buffer too short - does not work
    rdr = BoundedReader("abcd\nefg\r\n", 4)
    it = line_views(rdr; chomp = false)
    @test_throws ArgumentError iterate(it)
end

@testset "eachline basic functionality" begin
    # Test basic line iteration with strings
    io = GenericBufReader("line1\nline2\nline3")
    lines = collect(eachline(io))

    @test eltype(lines) == String
    @test length(lines) == 3
    @test lines == ["line1", "line2", "line3"]
end

@testset "eachline with keep=true" begin
    # Test keeping line endings
    io = GenericBufReader("hello\nworld\n")
    lines = collect(eachline(io, keep = true))
    @test lines == ["hello\n", "world\n"]

    # Test with \r\n
    io2 = GenericBufReader("line1\r\nline2\r\n")
    lines2 = collect(eachline(io2, keep = true))
    @test lines2 == ["line1\r\n", "line2\r\n"]

    # Test last line without newline
    io3 = GenericBufReader("line1\nline2")
    lines3 = collect(eachline(io3, keep = true))
    @test lines3 == ["line1\n", "line2"]
end


@testset "eachline edge cases" begin
    # Empty input
    empty_io = GenericBufReader("")
    empty_lines = collect(eachline(empty_io))
    @test isempty(empty_lines)

    # Single line without newline
    io1 = GenericBufReader("single")
    lines1 = collect(eachline(io1))
    @test lines1 == ["single"]

    # Only newlines
    io2 = GenericBufReader("\n\n")
    lines2 = collect(eachline(io2))
    @test lines2 == ["", ""]

    # Empty lines mixed with content
    io3 = GenericBufReader("a\n\nb")
    lines3 = collect(eachline(io3))
    @test lines3 == ["a", "", "b"]
end

@testset "Binary data handling" begin
    # Test with binary data containing various bytes
    binary_data = UInt8[
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x0a,  # "Hello\n"
        0x57, 0x6f, 0x72, 0x6c, 0x64, 0x0a,  # "World\n"
        0xFF, 0x00, 0x01, 0x0a,
    ]              # Binary + \n

    io = GenericBufReader(binary_data)
    lines = collect(line_views(io))

    @test length(lines) == 3
    @test String(lines[1]) == "Hello"
    @test String(lines[2]) == "World"
    @test lines[3] == [0xFF, 0x00, 0x01]  # Binary data preserved
end

@testset "with small growable buffer" begin
    io = IOBuffer("line1\r\nline2")
    reader = BufReader(io, 5)
    lines = line_views(reader)
    @test map(copy, lines) == [b"line1", b"line2"]
end

@testset "Iterator consistency" begin
    # Verify that line_views and eachline give consistent results
    test_data = "line1\nline2\r\nline3\n"

    io1 = GenericBufReader(test_data)
    views = collect(line_views(io1))

    io2 = GenericBufReader(test_data)
    strings = collect(eachline(io2))

    @test length(views) == length(strings)
    for (view, str) in zip(views, strings)
        @test String(view) == str
    end
end

@testset "line_views with MemoryView basic functionality" begin
    # Test basic line iteration with MemoryView
    mem = MemoryView("line1\nline2\nline3")
    iter = line_views(mem)

    # Test iterator properties
    @test eltype(iter) == ImmutableMemoryView{UInt8}
    @test Base.IteratorSize(typeof(iter)) == Base.SizeUnknown()

    # Collect all lines
    lines = collect(iter)
    @test lines isa Vector{ImmutableMemoryView{UInt8}}
    @test String.(lines) == ["line1", "line2", "line3"]

    # Test is stateless, as docs specify
    @test collect(iter) == lines

    # Test from mutable memory
    lit = line_views(MemoryView(collect(b"abcde\r\ndef\r\n")))
    lines = collect(lit)
    @test lines isa Vector{ImmutableMemoryView{UInt8}}
    @test lines == [b"abcde", b"def"]
end

@testset "line_views with MemoryView and chomp" begin
    # Test default chomping behavior
    mem = MemoryView("hello\nworld\n")
    lines = collect(line_views(mem))
    @test String.(lines) == ["hello", "world"]

    # Test with \r\n endings
    mem2 = MemoryView("line1\r\nline2\r\n")
    lines2 = collect(line_views(mem2; chomp = true))
    @test String.(lines2) == ["line1", "line2"]

    # Test with chomp=false
    mem3 = MemoryView(codeunits("a\nb\n"))
    lines3 = collect(line_views(mem3; chomp = false))
    @test String.(lines3) == ["a\n", "b\n"]
end

@testset "line_views with MemoryView edge cases" begin
    # Empty input
    @test isempty(collect(line_views(MemoryView(UInt8[]))))

    # Single line without newline
    mem1 = MemoryView("single line")
    @test collect(line_views(mem1)) == [b"single line"]

    # Only newlines
    mem2 = MemoryView("\n\n\n")
    lines2 = collect(line_views(mem2))
    @test String.(lines2) == ["", "", ""]

    # Single newline
    mem3 = MemoryView("\n")
    @test collect(line_views(mem3)) == [b""]
end

@testset "line_views MemoryView vs AbstractBufReader consistency" begin
    # Verify that line_views gives consistent results for same data
    test_data = "line1\nline2\r\nline3\n"

    # Using MemoryView
    mem = MemoryView(test_data)
    mem_lines = collect(line_views(mem))

    # Using AbstractBufReader
    reader = GenericBufReader(test_data)
    reader_lines = collect(line_views(reader))

    @test length(mem_lines) == length(reader_lines)
    for (mem_line, reader_line) in zip(mem_lines, reader_lines)
        @test mem_line == reader_line
    end
end
