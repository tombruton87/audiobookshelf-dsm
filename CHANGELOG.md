# Changelog

## 1.0.0 — 2026-10-11

First release. Audiobookshelf 2.37.1 in Container Manager:
- your audiobooks and podcasts from your shared folders: audiobooks read-only,
  podcasts writable for new episodes;
- your account is made at the first start, with the password shown once;
- the window works through an API key of the package's own, which it makes
  again by itself if it's removed in Audiobookshelf.

The DSM window adds:
- **Libraries:**
  - books, podcasts, episodes and hours, per library and in all;
  - scan one library or all, or read one again from scratch;
  - add a library from a shared folder: missing folders are refused, never
    created;
  - remove a library (its files stay);
  - a folder that goes away (a USB disk, a renamed share) shows as waiting and
    is read again when it's back.
- **Phones:** a QR code, the address, and the official apps.
- **Users:** add people, new passwords (shown once), administrator on or off,
  remove; listening and finished counts for each.
- **Updates:** Audiobookshelf's newer releases, installed after a backup.

Also included: consistent backups that keep everyone's listening progress
(Audiobookshelf's own backups are left alone), updates and removal.
