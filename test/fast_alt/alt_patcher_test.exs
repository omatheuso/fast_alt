defmodule FastAlt.AltPatcherTest do
  use ExUnit.Case, async: true

  alias FastAlt.AltPatcher

  setup do
    root = Path.join(System.tmp_dir!(), "alt_patcher_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_html(root, name, content) do
    path = Path.join(root, name)
    File.write!(path, content)
    path
  end

  defp read_html(path), do: File.read!(path)

  test "returns :ok immediately when patches list is empty", %{root: root} do
    path = write_html(root, "index.html", "<img src='hero.jpg'>")
    assert :ok = AltPatcher.patch_file(path, [])
    # File is untouched
    assert read_html(path) == "<img src='hero.jpg'>"
  end

  test "injects alt attribute on a matching img" , %{root: root} do
    path = write_html(root, "index.html", ~s|<img src="hero.jpg">|)
    assert :ok = AltPatcher.patch_file(path, [{"hero.jpg", "a hero image"}])

    html = read_html(path)
    assert html =~ ~s|alt="a hero image"|
    assert html =~ ~s|src="hero.jpg"|
  end

  test "replaces an existing alt attribute", %{root: root} do
    path = write_html(root, "index.html", ~s|<img src="hero.jpg" alt="old value">|)
    assert :ok = AltPatcher.patch_file(path, [{"hero.jpg", "new value"}])

    html = read_html(path)
    assert html =~ ~s|alt="new value"|
    refute html =~ ~s|alt="old value"|
  end

  test "patches multiple imgs in one pass", %{root: root} do
    html = ~s|<img src="a.jpg"><img src="b.png"><img src="c.gif">|
    path = write_html(root, "index.html", html)

    patches = [{"a.jpg", "first"}, {"b.png", "second"}, {"c.gif", "third"}]
    assert :ok = AltPatcher.patch_file(path, patches)

    result = read_html(path)
    assert result =~ ~s|alt="first"|
    assert result =~ ~s|alt="second"|
    assert result =~ ~s|alt="third"|
  end

  test "leaves unmatched imgs untouched", %{root: root} do
    html = ~s|<img src="a.jpg"><img src="b.png" alt="keep me">|
    path = write_html(root, "index.html", html)

    assert :ok = AltPatcher.patch_file(path, [{"a.jpg", "generated"}])

    result = read_html(path)
    assert result =~ ~s|alt="generated"|
    assert result =~ ~s|alt="keep me"|
  end

  test "returns {:error, reason} when file does not exist" do
    assert {:error, :enoent} = AltPatcher.patch_file("/nonexistent/file.html", [{"a.jpg", "x"}])
  end

  test "handles img tags nested inside other elements", %{root: root} do
    html = """
    <html><body>
      <div class="hero">
        <figure><img src="nested.jpg"></figure>
      </div>
    </body></html>
    """

    path = write_html(root, "index.html", html)
    assert :ok = AltPatcher.patch_file(path, [{"nested.jpg", "a nested image"}])

    result = read_html(path)
    assert result =~ ~s|alt="a nested image"|
  end
end
