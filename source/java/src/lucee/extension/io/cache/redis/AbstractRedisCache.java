package lucee.extension.io.cache.redis;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.Charset;
import java.io.IOException;
import java.io.ObjectInputStream;
import java.io.ObjectOutputStream;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Set;

import lucee.commons.io.cache.Cache;
import lucee.commons.io.cache.CacheEntry;
import lucee.commons.io.cache.CacheKeyFilter;
import lucee.commons.io.cache.CacheEntryFilter;
import lucee.commons.io.cache.exp.CacheException;
import lucee.extension.io.cache.util.ObjectInputStreamImpl;
import lucee.loader.engine.CFMLEngine;
import lucee.loader.engine.CFMLEngineFactory;
import lucee.loader.util.Util;
import lucee.runtime.config.Config;
import lucee.runtime.exp.PageException;
import lucee.runtime.type.Struct;
import lucee.runtime.util.Cast;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPoolConfig;
import redis.clients.jedis.exceptions.JedisDataException;

public abstract class AbstractRedisCache implements Cache {

    public static final Charset UTF8 = Charset.forName("UTF-8");

    protected CFMLEngine engine = CFMLEngineFactory.getInstance();
    protected Cast caster = engine.getCastUtil();

    protected int timeout;
    protected String password;

    private ClassLoader cl;
    private int defaultExpire;
    private String namespace;
    private int maxTotal;
    private int maxIdle;
    private int minIdle;

    public void init(Struct arguments) throws IOException {
        this.cl = arguments.getClass().getClassLoader();
        timeout = caster.toIntValue(arguments.get("timeout", null), 2000);
        password = caster.toString(arguments.get("password", null), null);
        if (Util.isEmpty(password)) password = null;

        defaultExpire = caster.toIntValue(arguments.get("timeToLiveSeconds", null), 0);
        namespace = caster.toString(arguments.get("namespace", null), null);
        if (Util.isEmpty(namespace)) namespace = null;

        maxTotal = caster.toIntValue(arguments.get("maxTotal", null), 0);
        maxIdle = caster.toIntValue(arguments.get("maxIdle", null), 0);
        minIdle = caster.toIntValue(arguments.get("minIdle", null), 0);
    }

    protected JedisPoolConfig getJedisPoolConfig() throws IOException {
        JedisPoolConfig config = new JedisPoolConfig();

        if (maxTotal > 0) config.setMaxTotal(maxTotal);
        if (maxIdle > 0) config.setMaxIdle(maxIdle);
        if (minIdle > 0) config.setMinIdle(minIdle);

        return config;
    }

    @Override
    public CacheEntry getCacheEntry(String skey) throws IOException {
        Jedis conn = jedisSilent();
        try {
            byte[] bkey = toJedisKey(skey);
            byte[] val = null;
            try {
                val = conn.get(bkey);
            }
            catch (JedisDataException jde) {
                String msg = jde.getMessage() + "";
                if (msg.startsWith("WRONGTYPE")) val = conn.lpop(bkey);
            }
            if (val == null) throw new IOException("Cache key [" + skey + "] does not exists");
            return new RedisCacheEntry(this, bkey, evaluate(val), val.length);
        }
        catch (PageException e) {
            throw new RuntimeException(e);// not throwing IOException because Lucee 4.5
        }
        finally {
            close(conn);
        }
    }

    @Override
    public Object getValue(String key) throws IOException {
        return getCacheEntry(key).getValue();
    }

    @Override
    public CacheEntry getCacheEntry(String key, CacheEntry defaultValue) {
        try {
            return getCacheEntry(key);
        }
        catch (IOException e) {
            return defaultValue;
        }
    }

    @Override
    public Object getValue(String key, Object defaultValue) {
        CacheEntry entry = getCacheEntry(key, null);
        if (entry == null) return defaultValue;
        return entry.getValue();
    }

    @Override
    public void put(String key, Object val, Long idle, Long expire) {
        Jedis conn = jedisSilent();
        try {
            byte[] bkey = toJedisKey(key);

            int ex = defaultExpire;

            if (expire != null) {
                ex = (int) (expire / 1000);
            }
            else if (idle != null) {
                // note: if this cache is being used as a session store
                // then idle will be passed in as -1 when a new session
                // is created and first stored. Avoid setting `ex` in
                // this case so we don't get a cache item without a TTL
                // when the cache has a default TTL
                if (idle >= 0) {
                    ex = (int) (idle / 1000);
                }
            }

            if (ex > 0) {
                conn.setex(bkey, ex, serialize(val));
            } else {
                conn.set(bkey, serialize(val));
            }
        }
        catch (PageException e) {
            throw new RuntimeException(e);// not throwing IOException because Lucee 4.5
        }
        finally {
            close(conn);
        }
    }

    @Override
    public boolean contains(String key) {
        Jedis conn = jedisSilent();
        try {
            return conn.exists(toJedisKey(key));
        }
        finally {
            close(conn);
        }
    }

    @Override
    public boolean remove(String key) throws IOException {
        Jedis conn = jedis();
        try {
            return conn.del(toJedisKey(key)) > 0;
        }
        finally {
            close(conn);
        }
    }

    @Override
    public int remove(CacheKeyFilter filter) throws IOException {
        Jedis conn = jedisSilent();

        try {
            List<byte[]> lkeys = _bkeys(conn, filter);
            if (lkeys == null || lkeys.size() == 0) return 0;
            Long rtn = conn.del(lkeys.toArray(new byte[lkeys.size()][]));
            if (rtn == null) return 0;
            return rtn.intValue();
        }
        finally {
            close(conn);
        }
    }

    @Override
    public int remove(CacheEntryFilter filter) throws IOException {
        if (CacheUtil.allowAll(filter)) return remove((CacheKeyFilter) null);

        List<String> keys = keys();
        int count = 0;
        Iterator<String> it = keys.iterator();
        String key;
        CacheEntry entry;
        while (it.hasNext()) {
            key = it.next();
            entry = getQuiet(key, null);
            if (filter == null || filter.accept(entry)) {
                remove(key);
                count++;
            }
        }
        return count;
    }

    @Override
    public List<String> keys() throws IOException {
        Jedis conn = jedis();
        try {
            return _skeys(conn, (CacheKeyFilter) null);
        }
        finally {
            close(conn);
        }
    }

    // private Set<String> _keys(Jedis conn) throws IOException {
    // return conn.keys("*");
    // }

    @Override
    public List<String> keys(CacheKeyFilter filter) throws IOException {
        Jedis conn = jedis();
        try {
            return _skeys(conn, filter);
        }
        finally {
            close(conn);
        }
    }

    @Override
    public List<String> keys(CacheEntryFilter filter) throws IOException {
        boolean all = CacheUtil.allowAll(filter);

        List<String> keys = keys();
        List<String> list = new ArrayList<String>();
        Iterator<String> it = keys.iterator();
        String key;
        CacheEntry entry;
        while (it.hasNext()) {
            key = it.next();
            entry = getQuiet(key, null);
            if (all || filter.accept(entry)) list.add(key);
        }
        return list;
    }

    @Override
    public List values() throws IOException {
        return values((CacheKeyFilter) null);
    }

    @Override
    public List values(CacheKeyFilter filter) throws IOException {
        Jedis conn = jedisSilent();

        try {
            List<byte[]> lkeys = _bkeys(conn, filter);
            List<Object> list = new ArrayList<Object>();

            if (lkeys == null || lkeys.size() == 0) return list;

            List<byte[]> values = conn.mget(lkeys.toArray(new byte[lkeys.size()][]));
            for (byte[] val: values) {
                list.add(evaluate(val));
            }
            return list;
        }
        catch (PageException e) {
            throw new RuntimeException(e);// not throwing IOException because Lucee 4.5
        }
        finally {
            close(conn);
        }
    }

    @Override
    public List values(CacheEntryFilter filter) throws IOException {
        if (CacheUtil.allowAll(filter)) return values();

        List<String> keys = keys();
        List<Object> list = new ArrayList<Object>();
        Iterator<String> it = keys.iterator();
        String key;
        CacheEntry entry;
        while (it.hasNext()) {
            key = it.next();
            entry = getQuiet(key, null);
            if (filter.accept(entry)) list.add(entry.getValue());
        }
        return list;
    }

    @Override
    public List<CacheEntry> entries() throws IOException {
        return entries((CacheKeyFilter) null);
    }

    @Override
    public List<CacheEntry> entries(CacheKeyFilter filter) throws IOException {
        Jedis conn = jedisSilent();

        try {
            List<byte[]> lkeys = _bkeys(conn, filter);
            List<CacheEntry> list = new ArrayList<CacheEntry>();

            if (lkeys == null || lkeys.size() == 0) return list;

            byte[][] keys = lkeys.toArray(new byte[lkeys.size()][]);

            List<byte[]> values = conn.mget(keys);
            if (keys.length == values.size()) { // because this is not atomar, it is possible that a key expired in meantime, but we try this way,
                                                // because it is much faster than the else solution
                int i = 0;
                for (byte[] val: values) {
                    list.add(new RedisCacheEntry(this, fromJedisKey(keys[i++]), evaluate(val), val.length));
                }
            }
            else {
                byte[] val;
                for (byte[] key: keys) {
                    val = null;
                    try {
                        val = conn.get(key);
                    }
                    catch (JedisDataException jde) {}
                    if (val != null) list.add(new RedisCacheEntry(this, fromJedisKey(key), evaluate(val), val.length));
                }
            }
            return list;
        }
        catch (PageException e) {
            throw new RuntimeException(e);// not throwing IOException because Lucee 4.5
        }
        finally {
            close(conn);
        }
    }

    @Override
    public List<CacheEntry> entries(CacheEntryFilter filter) throws IOException {
        List<CacheEntry> entries = entries();
        List<CacheEntry> list = new ArrayList<CacheEntry>();
        Iterator<CacheEntry> it = entries.iterator();
        CacheEntry entry;
        while (it.hasNext()) {
            entry = it.next();
            if (entry != null && filter.accept(entry)) {
                list.add(entry);
            }
        }
        return list;
    }

    @Override
    public long hitCount() {
        return 0;
    }

    @Override
    public long missCount() {
        return 0;
    }

    @Override
    public Struct getCustomInfo() {
        Jedis conn = jedisSilent();
        try {
            return InfoParser.parse(CacheUtil.getInfo(this), conn.info());// not throwing IOException because Lucee 4.5
        }
        finally {
            close(conn);
        }
    }

    public CacheEntry getQuiet(String key) throws IOException {
        CacheEntry entry = getQuiet(key, null);
        if (entry == null) throw new CacheException("there is no valid cache entry with key [" + key + "]");
        return entry;
    }

    public CacheEntry getQuiet(String key, CacheEntry defaultValue) {
        // TODO
        return getCacheEntry(key, defaultValue);
    }

    private List<byte[]> _bkeys(Jedis conn, CacheKeyFilter filter) throws IOException {
        boolean all = CacheUtil.allowAll(filter);
        Set<byte[]> skeys = conn.keys(toJedisKey("*"));
        List<byte[]> list = new ArrayList<byte[]>();
        Iterator<byte[]> it = skeys.iterator();
        byte[] key;
        while (it.hasNext()) {
            key = it.next();
            if (all || filter.accept(fromJedisKey(key))) list.add(key);
        }
        return list;
    }

    private List<String> _skeys(Jedis conn, CacheKeyFilter filter) throws IOException {
        boolean all = CacheUtil.allowAll(filter);
        Set<byte[]> skeys = conn.keys(toJedisKey("*"));
        List<String> list = new ArrayList<String>();
        Iterator<byte[]> it = skeys.iterator();
        byte[] key;
        while (it.hasNext()) {
            key = it.next();
            if (all || filter.accept(fromJedisKey(key))) list.add(fromJedisKey(key));
        }
        return list;
    }

    private byte[] toJedisKey(String key) {
        return addNamespace(key.trim().toLowerCase()).getBytes(UTF8);
    }

    private String fromJedisKey(byte[] jkey) {
        return removeNamespace(new String(jkey, UTF8));
    }

    private String addNamespace(String key) {
        if (namespace == null) return key;

        if (key.startsWith(namespace.toLowerCase() + ":")) {
            return key;
        }

        return namespace.toLowerCase() + ':' + key;
    }

    private String removeNamespace(String key) {
        if (namespace != null && key.startsWith(namespace.toLowerCase())) {
            return key.replace(namespace.toLowerCase() + ":", "");
        }
        return key;
    }

    private Object evaluate(byte[] data) throws PageException {
        ByteArrayInputStream bais = new ByteArrayInputStream(data);
        ObjectInputStream ois = null;
        try {
            ois = new ObjectInputStreamImpl(cl, bais);
            return ois.readObject();
        }
        catch (Exception e) {
            try {
                return new String(data, UTF8);
            } catch ( Exception innerE ) {
                throw CFMLEngineFactory.getInstance().getCastUtil().toPageException(e);
            }
        }
        finally {
            Util.closeEL(ois);
        }
    }

    private byte[] serialize(Object value) throws PageException {
    try {
            ByteArrayOutputStream os = new ByteArrayOutputStream(); // returns
            ObjectOutputStream oos = new ObjectOutputStream(os);
            oos.writeObject(value);
            oos.flush();
            return os.toByteArray();
        }
        catch (Exception e) {
            throw CFMLEngineFactory.getInstance().getCastUtil().toPageException(e);
        }
    }

    protected abstract Jedis jedis() throws IOException;

    protected Jedis jedisSilent() {
        try {
            return jedis();
        }
        catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    protected void close(Jedis conn) {
        if (conn != null) conn.close();
    }

}
