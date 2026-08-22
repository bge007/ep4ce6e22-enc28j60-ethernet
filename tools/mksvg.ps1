$ErrorActionPreference = "Stop"

$src = "C:\Users\BGeorge\AppData\Local\Temp\claude\C--BGE-AI-FPGA-EP4CE6E22\e0ede4f5-77b2-40ae-af38-92f613855a46\scratchpad\enc28j60-wiring-image.html"
$out = "C:\BGE\AI\FPGA\ep4ce6e22-enc28j60-ethernet\docs\wiring-diagram.svg"

$html = Get-Content $src -Raw
$svg  = [regex]::Match($html, '(?s)<svg viewBox="0 0 1080 1140".*?</svg>').Value
if (-not $svg) { throw "SVG not found in source" }

# Strip the source comments. They use rules like "<!-- ----- FPGA BOARD ----- -->",
# and a double hyphen is illegal inside an XML comment -- which a standalone
# .svg is parsed as, unlike SVG inlined in HTML.
$svg = [regex]::Replace($svg, '(?s)<!--.*?-->', '')
$svg = [regex]::Replace($svg, '(?m)^\s*\r?\n', '')

# Bake theme tokens into literals so the file stands alone.
$svg = $svg.Replace('currentColor', '#21282b')
$svg = $svg.Replace('var(--pcb)',      '#eaeee9')
$svg = $svg.Replace('var(--ink-soft)', '#69736e')
$svg = $svg.Replace('var(--card)',     '#ffffff')

# A standalone SVG needs the namespace, and it needs explicit width/height:
# with only a viewBox an <img> falls back to a 150px default intrinsic size,
# which renders the figure as a postage stamp on GitHub.
$svg = $svg -replace '^<svg ', '<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1140" '

# Opaque ground: keeps the figure legible on both GitHub themes.
$bg  = '<rect width="1080" height="1140" fill="#fbfcfa"/>'
$idx = $svg.IndexOf('>') + 1
$svg = $svg.Substring(0, $idx) + "`n  " + $bg + $svg.Substring($idx)

$header = @"
<!-- docs/wiring-diagram.svg
     Two-node EP4CE6E22 + ENC28J60 wiring. Colours are baked literals rather
     than CSS variables so the file renders standalone on GitHub. -->
"@

Set-Content -Path $out -Value ($header + "`n" + $svg) -Encoding utf8

$txt = Get-Content $out -Raw
$leftover = ([regex]::Matches($txt, 'var\(--')).Count + ([regex]::Matches($txt, 'currentColor')).Count
$hasNs    = $txt -match 'xmlns="http://www\.w3\.org/2000/svg"'
$kb       = [int]((Get-Item $out).Length / 1KB)

"written    : $out"
"size       : $kb KB"
"namespace  : $hasNs"
"leftovers  : $leftover"
