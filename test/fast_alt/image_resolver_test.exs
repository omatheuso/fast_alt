defmodule FastAlt.ImageResolverTest do
  use ExUnit.Case, async: true

  alias FastAlt.ImageResolver

  setup do
    root = Path.join(System.tmp_dir!(), "resolver_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "skips data URIs" do
    assert {:skip, "data URI"} =
             ImageResolver.resolve("data:image/png;base64,abc123", "/some/page.html")
  end

  test "skips http:// URLs" do
    assert {:skip, "external URL"} =
             ImageResolver.resolve("http://example.com/img.png", "/some/page.html")
  end

  test "skips https:// URLs" do
    assert {:skip, "external URL"} =
             ImageResolver.resolve("https://cdn.example.com/logo.svg", "/some/page.html")
  end

  test "skips protocol-relative URLs" do
    assert {:skip, "external URL"} =
             ImageResolver.resolve("//cdn.example.com/image.jpg", "/some/page.html")
  end

  test "skips relative path when file does not exist", %{root: root} do
    html_path = Path.join(root, "index.html")
    assert {:skip, _reason} = ImageResolver.resolve("missing.jpg", html_path)
  end

  test "resolves relative src in same directory as HTML file", %{root: root} do
    html_path = Path.join(root, "index.html")
    img_path = Path.join(root, "hero.jpg")
    File.write!(img_path, "")

    assert {:ok, ^img_path} = ImageResolver.resolve("hero.jpg", html_path)
  end

  test "resolves relative src in a subdirectory", %{root: root} do
    html_path = Path.join(root, "index.html")
    img_dir = Path.join(root, "images")
    File.mkdir_p!(img_dir)
    img_path = Path.join(img_dir, "photo.png")
    File.write!(img_path, "")

    assert {:ok, ^img_path} = ImageResolver.resolve("images/photo.png", html_path)
  end

  test "resolves relative src with parent directory traversal", %{root: root} do
    sub = Path.join(root, "pages")
    File.mkdir_p!(sub)
    html_path = Path.join(sub, "about.html")
    img_path = Path.join(root, "logo.svg")
    File.write!(img_path, "")

    assert {:ok, ^img_path} = ImageResolver.resolve("../logo.svg", html_path)
  end

  test "returns absolute path regardless of src format", %{root: root} do
    html_path = Path.join(root, "index.html")
    img_path = Path.join(root, "img.png")
    File.write!(img_path, "")

    assert {:ok, resolved} = ImageResolver.resolve("img.png", html_path)
    assert Path.type(resolved) == :absolute
  end
end
