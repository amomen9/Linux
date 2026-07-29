# Set up ACLs (`setfacl` / `getfacl`) on Linux

ACLs let you grant permissions to users/groups **without** changing the owner/group.

## Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y acl
```

## Common ACL commands

```bash
# Grant rwx to user 'bob' on a directory (recursive)
sudo setfacl -R -m u:bob:rwx /path/to/dir

# Revoke ACL entry
sudo setfacl -x u:alice /path/to/file.txt

# View ACLs
getfacl /path/to/file.txt
```

Tip: Prefer the smallest scope possible; avoid `-R` unless necessary.
