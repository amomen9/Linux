# Register and subscribe RHEL 9 with `subscription-manager`

Use this on **official Red Hat Enterprise Linux** installs.

## Steps

1. Register.

   ```bash
   sudo subscription-manager register --username <redhat-username> --password <redhat-password> --auto-attach
   ```

2. Verify status.

   ```bash
   sudo subscription-manager status
   sudo subscription-manager identity
   ```

Note: If your organization has Simple Content Access (SCA) enabled, auto-attach may be ignored. That can be normal.
