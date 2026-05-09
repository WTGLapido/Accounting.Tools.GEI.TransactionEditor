<#
.SYNOPSIS
    Decodes the <Transaction> base64 in a GEI XML file, applies field replacements
    interactively using XPath-style paths, re-encodes, and saves a new file.

.PARAMETER Path
    Path to the GEI XML file.

.PARAMETER OutputPath
    (Optional) Output path. Defaults to <original>_modified<ext> next to the source.

.EXAMPLE
    .\Edit-GEITransaction.ps1 -Path "C:\test\invoice.xml"

    Prompts interactively:
      Tag=Value: BranchAddress/Country/Code=AR
      Tag=Value: BranchAddress/Country/Name=Argentina
      Tag=Value:        <- Enter to finish
#>
param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Path,

    [string]$OutputPath
)

Set-StrictMode -Off
Add-Type -AssemblyName System.Xml.Linq

$InputPath = $Path -join ' '

# ---------------------------------------------------------------------------
# Validate input
# ---------------------------------------------------------------------------
if (-not (Test-Path $InputPath)) {
    Write-Error "File not found: $InputPath"
    exit 1
}

$content = Get-Content $InputPath -Raw -Encoding UTF8

if ($content -notmatch '(?s)<Transaction>(.*?)</Transaction>') {
    Write-Error 'No <Transaction> element found in file.'
    exit 1
}
$b64 = $Matches[1].Trim()

# ---------------------------------------------------------------------------
# Decode base64
# ---------------------------------------------------------------------------
try {
    $innerXmlStr = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
} catch {
    Write-Error "Failed to base64-decode Transaction: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Load as XDocument for precise navigation
# ---------------------------------------------------------------------------
try {
    $xdoc = [System.Xml.Linq.XDocument]::Parse($innerXmlStr)
} catch {
    Write-Error "Failed to parse inner XML: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Load outer envelope XML (plain, non-encoded fields)
# ---------------------------------------------------------------------------
$outerDoc        = $null
$outerWrapped    = $false   # true when we added a synthetic <_root_> wrapper
$outerParseError = $null
try {
    $outerDoc = [System.Xml.Linq.XDocument]::Parse($content)
} catch {
    $outerParseError = $_
    # Fallback: wrap in a synthetic root in case the file has no single root element
    try {
        $outerDoc     = [System.Xml.Linq.XDocument]::Parse('<_root_>' + $content + '</_root_>')
        $outerWrapped = $true
        $outerParseError = $null
    } catch {
        $outerDoc = $null
    }
}
$outerModified = $false

Write-Host ''
Write-Host 'Transaction decoded OK.' -ForegroundColor Cyan
Write-Host 'Commands (no prefix = inner Transaction XML):' -ForegroundColor DarkGray
Write-Host '  Path/To/Tag=Value        Replace a field (e.g. BranchAddress/Country/Code=AR)' -ForegroundColor DarkGray
Write-Host '  ?                        Explore all inner top-level elements' -ForegroundColor DarkGray
Write-Host '  ?BranchAddress           Explore <BranchAddress> in inner XML' -ForegroundColor DarkGray
if ($null -ne $outerDoc) {
    Write-Host 'Commands (@ prefix = outer envelope, plain XML):' -ForegroundColor DarkGray
    Write-Host '  @?                       Explore all outer envelope elements' -ForegroundColor DarkGray
    Write-Host '  @?SomeTag                Explore <SomeTag> in outer envelope' -ForegroundColor DarkGray
    Write-Host '  @Path/To/Tag=Value       Replace a field in the outer envelope' -ForegroundColor DarkGray
} else {
    Write-Host ('  [!] Outer envelope could not be parsed: {0}' -f $outerParseError) -ForegroundColor Yellow
}
Write-Host '  help                     Show full help' -ForegroundColor DarkGray
Write-Host '  <Enter>                  Save and exit' -ForegroundColor DarkGray
Write-Host ''

$modified = $false

# ---------------------------------------------------------------------------
# Helper: find all XElements matching a path segments array, starting from root descendants
# e.g. ["BranchAddress","Country","Code"] -> find all <Code> inside <Country> inside <BranchAddress>
# Segments may include (n) index notation, e.g. "RegistrationNumber(2)"
# ---------------------------------------------------------------------------
function Find-Elements {
    param(
        [System.Xml.Linq.XDocument]$doc,
        [string[]]$segments
    )

    # Parse each segment into { Name, Index } — Index=0 means no filter
    $segs = @($segments | ForEach-Object {
        if ($_ -match '^(.+)\((\d+)\)$') { @{ Name = $Matches[1]; Index = [int]$Matches[2] } }
        else                              { @{ Name = $_; Index = 0 } }
    })

    # If the first segment is the document root itself, skip it (root is not a descendant of itself)
    if ($segs.Length -gt 0 -and $null -ne $doc.Root -and $segs[0].Name -eq $doc.Root.Name.LocalName) {
        $segs = if ($segs.Length -gt 1) { $segs[1..($segs.Length - 1)] } else { @() }
        if ($segs.Length -eq 0) { return @($doc.Root) }
    }

    # Get all descendants matching a local name (ignores namespace)
    function Get-ByLocalName {
        param($container, [string]$localName)
        return @($container.Descendants() | Where-Object { $_.Name.LocalName -eq $localName })
    }

    # Return true if $el is the (1-based) $requiredIndex-th sibling with its local name
    function Test-Index {
        param([System.Xml.Linq.XElement]$el, [int]$requiredIndex)
        if ($requiredIndex -le 0) { return $true }
        $parent = $el.Parent
        if ($null -eq $parent) { return ($requiredIndex -eq 1) }
        $siblings = @($parent.Elements() | Where-Object { $_.Name.LocalName -eq $el.Name.LocalName })
        return (([Array]::IndexOf($siblings, $el) + 1) -eq $requiredIndex)
    }

    if ($segs.Length -eq 1) {
        $seg = $segs[0]
        return @(Get-ByLocalName $doc $seg.Name | Where-Object { Test-Index $_ $seg.Index })
    }

    $lastSeg   = $segs[-1]
    $parentSegs = $segs[0..($segs.Length - 2)]
    $parentSeg  = $parentSegs[-1]

    # Find all elements matching the immediate parent name (and index if specified)
    $candidates = @(Get-ByLocalName $doc $parentSeg.Name | Where-Object { Test-Index $_ $parentSeg.Index })

    $results = @()
    foreach ($candidate in $candidates) {
        # Verify the full ancestor chain (walking upward through parent segments)
        $node  = $candidate
        $match = $true
        for ($i = $parentSegs.Length - 2; $i -ge 0; $i--) {
            $node = $node.Parent
            if ($null -eq $node -or $node.Name.LocalName -ne $parentSegs[$i].Name) {
                $match = $false; break
            }
            if (-not (Test-Index $node $parentSegs[$i].Index)) {
                $match = $false; break
            }
        }
        if (-not $match) { continue }

        # Find children matching the last segment (with optional index)
        $children = @($candidate.Elements() | Where-Object { $_.Name.LocalName -eq $lastSeg.Name })
        if ($lastSeg.Index -gt 0) {
            if ($lastSeg.Index -le $children.Count) { $results += $children[$lastSeg.Index - 1] }
        } else {
            $results += $children
        }
    }
    return $results
}

# ---------------------------------------------------------------------------
# Helper: build the full XPath-style path for an element, with (n) indices for collection items
# ---------------------------------------------------------------------------
function Get-ElementPath {
    param([System.Xml.Linq.XElement]$el)
    $segments = @()
    $current = $el
    while ($null -ne $current -and $current.NodeType -ne [System.Xml.XmlNodeType]::Document) {
        $localName = $current.Name.LocalName
        $parent    = $current.Parent
        $label     = $localName
        if ($null -ne $parent -and $parent.NodeType -ne [System.Xml.XmlNodeType]::Document) {
            $siblings = @($parent.Elements() | Where-Object { $_.Name.LocalName -eq $localName })
            if ($siblings.Count -gt 1) {
                $idx   = [Array]::IndexOf($siblings, $current) + 1
                $label = '{0}({1})' -f $localName, $idx
            }
        }
        $segments = @($label) + $segments
        $current  = $parent
    }
    return $segments -join '/'
}

# ---------------------------------------------------------------------------
# Helper: print element tree recursively
# ---------------------------------------------------------------------------
function Print-Tree {
    param(
        [System.Xml.Linq.XElement]$el,
        [string]$prefix = '',
        [int]$maxDepth = 6,
        [int]$depth = 0
    )
    $children = @($el.Elements())
    $path = Get-ElementPath $el

    if ($children.Count -eq 0) {
        # Leaf node — show path and value (truncate very long values like base64)
        $val = if ($el.Value.Length -gt 80) { $el.Value.Substring(0, 77) + '...' } else { $el.Value }
        Write-Host ('  {0} = "{1}"' -f $path, $val) -ForegroundColor DarkGray
    } elseif ($depth -ge $maxDepth) {
        # Hit depth limit — show summary so collections are never invisible
        Write-Host ('  {0}/... ({1} child(ren) - use ?{0} to expand)' -f $path, $children.Count) -ForegroundColor DarkYellow
    } else {
        foreach ($child in $children) {
            Print-Tree $child -depth ($depth + 1) -maxDepth $maxDepth
        }
    }
}

# ---------------------------------------------------------------------------
# Interactive loop
# ---------------------------------------------------------------------------
do {
    $line = Read-Host 'Tag=Value'
    if ([string]::IsNullOrWhiteSpace($line)) { break }

    # --- help ---
    if ($line -match '^help$') {
        Write-Host ''
        Write-Host 'COMMANDS' -ForegroundColor Cyan
        Write-Host '  ?                        List all inner top-level elements' -ForegroundColor DarkGray
        Write-Host '  ?BranchAddress           Show tree for <BranchAddress> in inner XML' -ForegroundColor DarkGray
        Write-Host '  ?BranchAddress/Country   Show tree for <Country> inside <BranchAddress>' -ForegroundColor DarkGray
        Write-Host '  @?                       List all outer envelope elements (plain XML)' -ForegroundColor DarkGray
        Write-Host '  @?SomeTag                Show tree for <SomeTag> in outer envelope' -ForegroundColor DarkGray
        Write-Host '  help                     Show this help' -ForegroundColor DarkGray
        Write-Host '  <Enter>                  Save and exit' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'REPLACEMENTS' -ForegroundColor Cyan
        Write-Host '  Tag=Value                Replace ALL <Tag> elements anywhere in the XML' -ForegroundColor DarkGray
        Write-Host '  Parent/Tag=Value         Replace <Tag> inside <Parent> only' -ForegroundColor DarkGray
        Write-Host '  A/B/C=Value              Replace <C> inside <B> inside <A> (any depth)' -ForegroundColor DarkGray
        Write-Host '  A/B(2)/C=Value           Replace <C> inside the 2nd <B> only (1-based index)' -ForegroundColor DarkGray
        Write-Host '  @Tag=Value               Replace <Tag> in the outer envelope (plain XML)' -ForegroundColor DarkGray
        Write-Host '  @A/B/C=Value             Replace <C> inside <B>/<A> in the outer envelope' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'COLLECTION ITEM INDEXING' -ForegroundColor Cyan
        Write-Host '  When a path is shown as  Foo/Bar(2)/Value, it means the 2nd <Bar> in <Foo>.' -ForegroundColor DarkGray
        Write-Host '  Use the same (n) notation to target that specific item:' -ForegroundColor DarkGray
        Write-Host '  RegistrationNumberCollection/RegistrationNumber(2)/Value=NEW' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'EXAMPLES (inner Transaction XML - no prefix)' -ForegroundColor Cyan
        Write-Host '  BranchAddress/Country/Code=AR' -ForegroundColor DarkGray
        Write-Host '  BranchAddress/Country/Name=Argentina' -ForegroundColor DarkGray
        Write-Host '  BranchAddress/City=Buenos Aires' -ForegroundColor DarkGray
        Write-Host '  BranchAddress/Address1=Guemes 3381' -ForegroundColor DarkGray
        Write-Host '  RegistrationNumberCollection/RegistrationNumber(3)/Value=987654' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'EXAMPLES (outer envelope - @ prefix)' -ForegroundColor Cyan
        Write-Host '  @?                                                           explore all envelope elements' -ForegroundColor DarkGray
        Write-Host '  @?AdditionalDataItems                                        explore AdditionalDataItems tree' -ForegroundColor DarkGray
        Write-Host '  @AdditionalDataItems/AdditionalDataItem(3)/Value=nuevo       replace 3rd item value' -ForegroundColor DarkGray
        Write-Host '  @GlobalElectronicInvoicing/Header/.../AdditionalDataItem(3)/Value=nuevo  (full path also works)' -ForegroundColor DarkGray
        Write-Host ''
        continue
    }

    # --- @? or @?SomePath — explore outer envelope ---
    if ($line -match '^@\?(.*)$') {
        if ($null -eq $outerDoc) {
            Write-Host '  [!] Outer envelope XML is not available.' -ForegroundColor Yellow
            continue
        }
        $filter = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($filter)) {
            $topLevel = @($outerDoc.Root.Elements())
            Write-Host ('  [ENVELOPE] Top-level elements ({0}):' -f $topLevel.Count) -ForegroundColor Magenta
            foreach ($el in $topLevel) {
                Write-Host ('  [{0}]' -f $el.Name.LocalName) -ForegroundColor Magenta
                Print-Tree $el -maxDepth 6
                Write-Host ''
            }
        } else {
            $segs = ($filter.TrimEnd('/') -split '/') | Where-Object { $_ -ne '' }
            $found = Find-Elements -doc $outerDoc -segments $segs
            if ($found.Count -eq 0) {
                Write-Host ('  [!] No elements found in envelope for: {0}' -f $filter) -ForegroundColor Yellow
            } else {
                foreach ($el in $found) {
                    Write-Host ('[ENVELOPE] [{0}]' -f $el.Name.LocalName) -ForegroundColor Magenta
                    Print-Tree $el -maxDepth 6
                    Write-Host ''
                }
            }
        }
        continue
    }

    # --- @Path=Value — replace in outer envelope ---
    if ($line -match '^@([^=]+)=(.*)$') {
        if ($null -eq $outerDoc) {
            Write-Host '  [!] Outer envelope XML is not available.' -ForegroundColor Yellow
            continue
        }
        $lhs    = $Matches[1].Trim()
        $newVal = $Matches[2].Trim()
        # Remove leading/trailing double quotes if present
        if ($newVal.Length -ge 2 -and $newVal.StartsWith('"') -and $newVal.EndsWith('"')) {
            $newVal = $newVal.Substring(1, $newVal.Length - 2)
        }
        $segs   = ($lhs.TrimEnd('/') -split '/') | Where-Object { $_ -ne '' }
        $elements = Find-Elements -doc $outerDoc -segments $segs
        if ($elements.Count -eq 0) {
            Write-Host ('  [!] No elements found in envelope for path: {0}' -f $lhs) -ForegroundColor Yellow
        } else {
            foreach ($el in $elements) {
                $displayPath = Get-ElementPath $el
                $oldVal = if ($el.Value.Length -gt 60) { $el.Value.Substring(0, 57) + '...' } else { $el.Value }
                Write-Host ('  --> [ENVELOPE] [{0}] "{1}"  =>  "{2}"' -f $displayPath, $oldVal, $newVal) -ForegroundColor Magenta
                $el.Value = $newVal
            }
            Write-Host ('  [OK] {0} envelope replacement(s) applied.' -f $elements.Count) -ForegroundColor Green
            $outerModified = $true
        }
        continue
    }

    # --- ? or ?SomePath — explore mode ---
    if ($line -match '^\?(.*)$') {
        $filter = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($filter)) {
            # Show all top-level children of the root
            $topLevel = @($xdoc.Root.Elements())
            Write-Host ('  Top-level elements ({0}):' -f $topLevel.Count) -ForegroundColor Cyan
            foreach ($el in $topLevel) {
                Write-Host ('  [{0}]' -f $el.Name.LocalName) -ForegroundColor Cyan
                Print-Tree $el -maxDepth 6
                Write-Host ''
            }
        } else {
            # Show tree for elements matching the name
            $segs = ($filter.TrimEnd('/') -split '/') | Where-Object { $_ -ne '' }
            $found = Find-Elements -doc $xdoc -segments $segs
            if ($found.Count -eq 0) {
                Write-Host ('  [!] No elements found for: {0}' -f $filter) -ForegroundColor Yellow
            } else {
                foreach ($el in $found) {
                    Write-Host ('[{0}]' -f $el.Name.LocalName) -ForegroundColor Cyan
                    Print-Tree $el -maxDepth 6
                    Write-Host ''
                }
            }
        }
        continue
    }

    if ($line -notmatch '^([^=]+)=(.*)$') {
        Write-Host '  [!] Expected format: Path/To/Tag=Value  or  ?  or  ?Path/To/Tag' -ForegroundColor Yellow
        continue
    }

    $lhs    = $Matches[1].Trim()
    $newVal = $Matches[2].Trim()
    # Remove leading/trailing double quotes if present
    if ($newVal.Length -ge 2 -and $newVal.StartsWith('"') -and $newVal.EndsWith('"')) {
        $newVal = $newVal.Substring(1, $newVal.Length - 2)
    }
    $segs   = $lhs -split '/'

    $elements = Find-Elements -doc $xdoc -segments $segs

    if ($elements.Count -eq 0) {
        Write-Host ('  [!] No elements found for path: {0}' -f $lhs) -ForegroundColor Yellow
        if ($null -ne $outerDoc) {
            Write-Host '      Tip: use @Path/To/Tag=Value to replace fields in the outer envelope.' -ForegroundColor DarkGray
        }
    } else {
        foreach ($el in $elements) {
            $displayPath = Get-ElementPath $el
            Write-Host ('  --> [{0}] "{1}"  =>  "{2}"' -f $displayPath, $el.Value, $newVal) -ForegroundColor DarkGray
            $el.Value = $newVal
        }
        Write-Host ('  [OK] {0} replacement(s) applied.' -f $elements.Count) -ForegroundColor Green
        $modified = $true
    }

} while ($true)

if (-not $modified -and -not $outerModified) {
    Write-Host 'No changes made. Exiting.' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Re-encode inner XML
# ---------------------------------------------------------------------------
$newInnerXml = $xdoc.ToString([System.Xml.Linq.SaveOptions]::DisableFormatting)
$newB64      = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($newInnerXml))

if (-not $OutputPath) {
    $dir        = Split-Path $InputPath -Parent
    $name       = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $ext        = [System.IO.Path]::GetExtension($InputPath)
    $OutputPath = Join-Path $dir ($name + '_modified' + $ext)
}

if ($outerModified -and $null -ne $outerDoc) {
    # Outer envelope was modified — update Transaction element and serialize whole doc
    $transEl = @($outerDoc.Descendants() | Where-Object { $_.Name.LocalName -eq 'Transaction' }) | Select-Object -First 1
    if ($null -ne $transEl) { $transEl.Value = $newB64 }
    $serialized = $outerDoc.ToString([System.Xml.Linq.SaveOptions]::DisableFormatting)
    # If we wrapped in a synthetic root, strip it off
    if ($outerWrapped) {
        $serialized = [regex]::Replace($serialized, '^<_root_>', '')
        $serialized = [regex]::Replace($serialized, '</_root_>$', '')
    }
    $newContent = $serialized
} else {
    # Only inner XML changed — regex replace preserves outer formatting exactly
    $newContent = [regex]::Replace($content, '(?s)<Transaction>.*?</Transaction>', ('<Transaction>' + $newB64 + '</Transaction>'))
}

[System.IO.File]::WriteAllText($OutputPath, $newContent, [System.Text.Encoding]::UTF8)

Write-Host ''
Write-Host ('Saved: {0}' -f $OutputPath) -ForegroundColor Cyan
