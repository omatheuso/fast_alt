defmodule FastAlt.FileScannerTest do
  use ExUnit.Case, async: true

  alias FastAlt.FileScanner

  setup do
    root = Path.join(System.tmp_dir!(), "file_scanner_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "returns empty list for empty directory", %{root: root} do
    assert FileScanner.find_html_files(root) == []
  end

  test "returns empty list for non-existent directory" do
    assert FileScanner.find_html_files("/tmp/does_not_exist_fast_alt") == []
  end

  test "finds .html files", %{root: root} do
    File.write!(Path.join(root, "index.html"), "")
    File.write!(Path.join(root, "about.html"), "")

    result = FileScanner.find_html_files(root)
    assert length(result) == 2
    assert Enum.all?(result, &String.ends_with?(&1, ".html"))
  end

  test "finds .htm files", %{root: root} do
    File.write!(Path.join(root, "old.htm"), "")

    result = FileScanner.find_html_files(root)
    assert result == [Path.join(root, "old.htm")]
  end

  test "ignores non-HTML files", %{root: root} do
    File.write!(Path.join(root, "styles.css"), "")
    File.write!(Path.join(root, "app.js"), "")
    File.write!(Path.join(root, "index.html"), "")

    result = FileScanner.find_html_files(root)
    assert result == [Path.join(root, "index.html")]
  end

  test "recurses into subdirectories", %{root: root} do
    sub = Path.join(root, "nested/deep")
    File.mkdir_p!(sub)
    File.write!(Path.join(root, "index.html"), "")
    File.write!(Path.join(sub, "page.html"), "")

    result = FileScanner.find_html_files(root)
    assert length(result) == 2
    assert Path.join(root, "index.html") in result
    assert Path.join(sub, "page.html") in result
  end

  test "returns sorted paths", %{root: root} do
    File.write!(Path.join(root, "z.html"), "")
    File.write!(Path.join(root, "a.html"), "")
    File.write!(Path.join(root, "m.html"), "")

    result = FileScanner.find_html_files(root)
    assert result == Enum.sort(result)
  end

  test "returns absolute paths", %{root: root} do
    File.write!(Path.join(root, "index.html"), "")

    [path] = FileScanner.find_html_files(root)
    assert Path.type(path) == :absolute
  end
end
