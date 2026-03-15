defmodule FastAlt.HTMLScannerTest do
  use ExUnit.Case, async: true

  alias FastAlt.HTMLScanner

  test "returns empty list when there are no img tags" do
    assert HTMLScanner.scan_html("<html><body><p>No images here</p></body></html>") == []
  end

  test "alt: nil when alt attribute is absent" do
    [entry] = HTMLScanner.scan_html(~s|<img src="hero.jpg">|)
    assert entry.src == "hero.jpg"
    assert entry.alt == nil
  end

  test "alt: empty string when alt attribute is present but blank" do
    [entry] = HTMLScanner.scan_html(~s|<img src="hero.jpg" alt="">|)
    assert entry.src == "hero.jpg"
    assert entry.alt == ""
  end

  test "alt: value when alt attribute has text" do
    [entry] = HTMLScanner.scan_html(~s|<img src="hero.jpg" alt="a hero image">|)
    assert entry.src == "hero.jpg"
    assert entry.alt == "a hero image"
  end

  test "handles multiple img tags" do
    html = ~s|<img src="a.jpg" alt="first"><img src="b.png"><img src="c.gif" alt="">|
    results = HTMLScanner.scan_html(html)

    assert length(results) == 3
    assert Enum.find(results, &(&1.src == "a.jpg")).alt == "first"
    assert Enum.find(results, &(&1.src == "b.png")).alt == nil
    assert Enum.find(results, &(&1.src == "c.gif")).alt == ""
  end

  test "skips img tags with no src attribute" do
    html = ~s|<img alt="no src here"><img src="valid.jpg">|
    results = HTMLScanner.scan_html(html)

    assert length(results) == 1
    assert hd(results).src == "valid.jpg"
  end

  test "handles malformed HTML gracefully" do
    # Missing closing tags and improperly nested elements — common in generated output
    html = "<div><p><img src=\"broken.jpg\" alt=\"test\"></div>"
    results = HTMLScanner.scan_html(html)

    assert length(results) == 1
    assert hd(results).src == "broken.jpg"
    assert hd(results).alt == "test"
  end

  test "finds img tags nested deep in the document" do
    html = """
    <html>
      <body>
        <div class="wrapper">
          <section>
            <figure>
              <img src="nested.jpg" alt="nested image">
            </figure>
          </section>
        </div>
      </body>
    </html>
    """

    [entry] = HTMLScanner.scan_html(html)
    assert entry.src == "nested.jpg"
    assert entry.alt == "nested image"
  end

  test "preserves order of img tags" do
    html = ~s|<img src="first.jpg"><img src="second.jpg"><img src="third.jpg">|
    results = HTMLScanner.scan_html(html)

    assert Enum.map(results, & &1.src) == ["first.jpg", "second.jpg", "third.jpg"]
  end
end
