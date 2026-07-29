# Install EPEL on RHEL 9 (and derivatives)

EPEL (Extra Packages for Enterprise Linux) provides additional packages maintained by the Fedora community.

## RHEL 9 (official RHEL)

1. Update your system.

   ```bash
   sudo dnf update -y
   ```

2. Ensure `subscription-manager` exists.

   ```bash
   sudo dnf install -y subscription-manager
   ```

3. Enable the CodeReady Builder (CRB) repo.

   ```bash
   sudo subscription-manager repos --enable "codeready-builder-for-rhel-9-$(arch)-rpms"
   ```

4. Install EPEL.

   ```bash
   sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
   ```

5. Verify.

   ```bash
   sudo dnf repolist
   sudo dnf --disablerepo='*' --enablerepo=epel list available | head
   ```

## Rocky/Alma/CentOS Stream notes

- On Rocky/Alma 9, the old `powertools` repo is now `crb`.
