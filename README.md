# GEI Transaction Editor

A PowerShell script for editing GEI (Global Electronic Invoicing) XML files in CargoWise.
It decodes the base64-encoded `<Transaction>` element, lets you interactively replace fields
using XPath-style paths, then re-encodes and saves the modified file — all without needing
an XML editor or manual base64 decoding.

## Usage

```powershell
.\Edit-GEITransaction.ps1 -Path "C:\path\to\invoice.xml"
```

An optional `-OutputPath` parameter lets you specify where to save the result.
By default, the output is saved next to the source file as `<name>_modified<ext>`.

```powershell
.\Edit-GEITransaction.ps1 -Path "C:\path\to\invoice.xml" -OutputPath "C:\path\to\output.xml"
```

## Interactive Commands

Once the file is loaded, you'll be prompted to enter commands one at a time.
Press **Enter** on an empty line to save and exit.

### Explore the XML structure

| Command | Description |
|---|---|
| `?` | List all top-level elements in the inner Transaction XML |
| `?BranchAddress` | Show the tree for `<BranchAddress>` in the inner XML |
| `?BranchAddress/Country` | Show the tree for `<Country>` inside `<BranchAddress>` |
| `@?` | List all top-level elements in the outer envelope (plain XML) |
| `@?AdditionalDataItems` | Show the tree for `<AdditionalDataItems>` in the outer envelope |
| `help` | Show the full in-tool help |
| *(empty line)* + Enter | **Save all changes and exit** |

### Replace field values

| Command | Description |
|---|---|
| `Tag=Value` | Replace **all** `<Tag>` elements anywhere in the Transaction XML |
| `Parent/Tag=Value` | Replace `<Tag>` inside `<Parent>` only |
| `A/B/C=Value` | Replace `<C>` inside `<B>` inside `<A>` (any depth) |
| `A/B(2)/C=Value` | Replace `<C>` inside the **2nd** `<B>` only (1-based index) |
| `@Tag=Value` | Replace `<Tag>` in the **outer envelope** (plain XML, not Transaction) |
| `@A/B/C=Value` | Replace `<C>` inside `<B>`/`<A>` in the outer envelope |

### Example session

```
Transaction decoded OK.

Tag=Value: BranchAddress/Country/Code=AR
  --> [BranchAddress/Country/Code] "US"  =>  "AR"
  [OK] 1 replacement(s) applied.

Tag=Value: BranchAddress/Country/Name=Argentina
  --> [BranchAddress/Country/Name] "United States"  =>  "Argentina"
  [OK] 1 replacement(s) applied.

Tag=Value: BranchAddress/City=Buenos Aires
  --> [BranchAddress/City] "New York"  =>  "Buenos Aires"
  [OK] 1 replacement(s) applied.

Tag=Value: RegistrationNumberCollection/RegistrationNumber(2)/Value=20123456789
  --> [RegistrationNumberCollection/RegistrationNumber(2)/Value] "00000000"  =>  "20123456789"
  [OK] 1 replacement(s) applied.

Tag=Value:
Saved: C:\path\to\invoice_modified.xml
```

## Notes

- The script targets the **inner** Transaction XML (base64-decoded) by default.
  Use the `@` prefix to target the **outer** envelope instead.
- When a path shows `Foo/Bar(2)/Value` in the explore output, it means the 2nd `<Bar>` in `<Foo>`.
  Use the same `(n)` notation to target that specific item.
- Values wrapped in double quotes are automatically unquoted (e.g. `Tag="value"` → `value`).
- The output file is UTF-8 encoded. The original file encoding is preserved as-is in the outer envelope.
