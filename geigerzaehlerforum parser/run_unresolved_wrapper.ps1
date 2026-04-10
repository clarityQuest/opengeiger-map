try {
  & .\unresolved_focus_pass.ps1
  Set-Content .\_unresolved_focus_status.txt -Value "ok" -Encoding utf8
} catch {
  Set-Content .\_unresolved_focus_status.txt -Value ("error: " + $_.Exception.Message) -Encoding utf8
}
