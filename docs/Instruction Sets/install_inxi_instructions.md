# Install `inxi` (system information tool)

`inxi` prints a compact but detailed hardware/software summary.

## RHEL/Rocky/Alma 9

1. Enable CRB (was `powertools` on older releases).

   ```bash
   sudo dnf config-manager --set-enabled crb || sudo dnf config-manager --set-enabled powertools
   ```

2. Install EPEL if you do not already have it.

   See [Install EPEL on RHEL 9](install_epel_rhel9_instructions.md).

3. Install `inxi`.

   ```bash
   sudo dnf install -y inxi || sudo yum install -y inxi
   ```

4. Run it.

   ```bash
   inxi -Fxz
   ```

If you get Perl dependency errors (example: `perl(JSON::XS)`), install the missing Perl module:

```bash
sudo dnf install -y perl-JSON-XS
```
