## Lucee Redis Cache Extension

This is a fork of the official Lucee Redis extension: <https://github.com/lucee/extension-redis>

I created it so that I could modify a few things from the official extension:

- Added support for defining a namespace (key prefix) for all keys stored in the cache. This makes it easier for
  multiple caches to use the same Redis instance without clashing
- Respect a cache put with an idle timeout (by setting a ttl on the key). This allows the cache to be used for Lucee
  session storage without having the keys either last forever or expire according the the cache level ttl.
- Avoid setting keys with no expiration when Lucee passes in an idle timeout of -1. This can happens with older versions
  of Lucee when a new session is created, with the result that session keys with no expiration will be present in the
  cache.

As the official extension is worked on, I may or may not maintain this to match, or just switch back to it.

### License

The official repository does not currently carry a license, but other Lucee extensions are licensed via LGPLv2.1, so I
have added that license here.


### Building the Extension

Clone the repository to a new directory, and then via CommandBox, execute the task runner (`task.cfc`) in the repository
root:

```bash
task run
```
Java does need to be on your path as the task runner uses the Java Compiler (`javac`).
