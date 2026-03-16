defmodule FastAlt.ScannerTest do
  use ExUnit.Case, async: true

  alias FastAlt.Scanner

  # Minimal 1×1 white PNG (valid binary, parseable by File.exists? check only)
  @tiny_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
              1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99, 248,
              207, 192, 0, 0, 0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
              130, 130>>

  setup do
    root = Path.join(System.tmp_dir!(), "scanner_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp stub_caption_fn(caption \\ "a generated caption") do
    fn _path -> caption end
  end

  defp write_html(root, name, content) do
    path = Path.join(root, name)
    File.write!(path, content)
    path
  end

  defp write_image(root, name) do
    path = Path.join(root, name)
    File.write!(path, @tiny_png)
    path
  end

  test "returns {:ok, []} for empty directory", %{root: root} do
    assert {:ok, []} = Scanner.scan(root, caption_fn: stub_caption_fn())
  end

  test "returns {:ok, []} when no HTML files exist", %{root: root} do
    File.write!(Path.join(root, "styles.css"), "body {}")
    assert {:ok, []} = Scanner.scan(root, caption_fn: stub_caption_fn())
  end

  test "returns {:error, _} for a non-existent directory" do
    assert {:error, _} = Scanner.scan("/tmp/does_not_exist_fast_alt_scanner")
  end

  test "returns {:error, _} for a file path instead of a directory", %{root: root} do
    file = Path.join(root, "notadir.html")
    File.write!(file, "")
    assert {:error, _} = Scanner.scan(file, caption_fn: stub_caption_fn())
  end

  test "finds img with absent alt and returns a result", %{root: root} do
    write_image(root, "hero.jpg")
    write_html(root, "index.html", ~s|<img src="hero.jpg">|)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert result.img_src == "hero.jpg"
    assert result.generated_alt == "a generated caption"
    assert result.skipped == false
    assert result.patched == false
  end

  test "finds img with empty alt and returns a result", %{root: root} do
    write_image(root, "hero.jpg")
    write_html(root, "index.html", ~s|<img src="hero.jpg" alt="">|)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert result.img_src == "hero.jpg"
  end

  test "ignores img that already has non-empty alt", %{root: root} do
    write_image(root, "hero.jpg")
    write_html(root, "index.html", ~s|<img src="hero.jpg" alt="already set">|)

    assert {:ok, []} = Scanner.scan(root, caption_fn: stub_caption_fn())
  end

  test "skips external URLs and marks result as skipped", %{root: root} do
    write_html(root, "index.html", ~s|<img src="https://example.com/img.jpg">|)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert result.skipped == true
    assert result.skip_reason =~ "external"
    assert result.generated_alt == nil
  end

  test "skips data URIs and marks result as skipped", %{root: root} do
    write_html(root, "index.html", ~s|<img src="data:image/png;base64,abc">|)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert result.skipped == true
    assert result.skip_reason =~ "data URI"
  end

  test "skips missing image files and marks result as skipped", %{root: root} do
    write_html(root, "index.html", ~s|<img src="missing.jpg">|)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert result.skipped == true
  end

  test "patches HTML file in-place when patch: true", %{root: root} do
    write_image(root, "hero.jpg")
    html_path = write_html(root, "index.html", ~s|<img src="hero.jpg">|)

    assert {:ok, [result]} =
             Scanner.scan(root, patch: true, caption_fn: stub_caption_fn("patched alt"))

    assert result.patched == true
    assert File.read!(html_path) =~ ~s|alt="patched alt"|
  end

  test "does not patch when patch: false (default)", %{root: root} do
    write_image(root, "hero.jpg")
    html_path = write_html(root, "index.html", ~s|<img src="hero.jpg">|)
    original = File.read!(html_path)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())

    assert result.patched == false
    assert File.read!(html_path) == original
  end

  test "scans multiple HTML files", %{root: root} do
    write_image(root, "a.jpg")
    write_image(root, "b.jpg")
    write_html(root, "page1.html", ~s|<img src="a.jpg">|)
    write_html(root, "page2.html", ~s|<img src="b.jpg">|)

    assert {:ok, results} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert length(results) == 2
  end

  test "recurses into subdirectories", %{root: root} do
    sub = Path.join(root, "nested")
    File.mkdir_p!(sub)
    write_image(sub, "img.jpg")
    write_html(sub, "page.html", ~s|<img src="img.jpg">|)

    assert {:ok, [result]} = Scanner.scan(root, caption_fn: stub_caption_fn())
    assert result.img_src == "img.jpg"
  end
end
