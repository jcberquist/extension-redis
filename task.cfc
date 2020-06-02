component {

    property name="progressableDownloader" inject="ProgressableDownloader";
    property name="progressBar" inject="ProgressBar";

    function run() {
        var baseDir = resolvePath( './' ).replace( '\', '/', 'all' );
        var boxJson = readBoxJson();

        prepare( baseDir );
        compile( baseDir, boxJson );
        lex( baseDir, boxJson );
        clean( baseDir );

        print.greenLine( 'All Done! Extension is at dist/redis.extension-#boxJson.version#.lex' ).toConsole();
    }

    function compile( baseDir, boxJson ) {
        var allJars = [ ].append( boxJson.jars.compile, true ).append( boxJson.jars.dist, true );
        var relativePath = ( p ) => p.replace( '\', '/', 'all' ).replace( baseDir, '' );

        fetchJars( baseDir, allJars );

        var javaFiles = directoryList(
            baseDir & 'src/',
            true,
            'path',
            '*.java'
        ).map( relativePath );

        print.line( 'Compiling java files...' );
        for ( var jf in javaFiles ) {
            print.indentedGreenLine( jf );
        }
        print.line().toConsole();


        command( '!javac' )
            .params( '-d', baseDir & 'dist/classes/' )
            .params( '-cp', allJars.map( ( p ) => 'lib/' & p.listLast( '/' ) ).toList( ';' ) )
            .params( '-source', '1.7' )
            .params( '-target', '1.7' )
            .params( '-g:lines,vars,source' )
            .params( argumentCollection = javaFiles )
            .run();

        var manifest = {
            'Bundle-Version': '#boxJson.version#',
            'Built-Date': dateTimeFormat( now(), 'yyyy-mm-dd hh:nn:ss' ),
            'Bundle-SymbolicName': 'redis.extension',
            'Export-Package': 'lucee.extension.io.cache.redis.simple,lucee.extension.io.cache.redis.sentinel',
            'Bundle-ManifestVersion': '2',
            'Require-Bundle': requireBundle( boxJson )
        };

        print.line( 'Creating lucee.extension.redis-#boxJson.version#.jar' ).toConsole();
        jar( '#baseDir#dist/classes/', '#baseDir#dist/lex/jars/lucee.extension.redis-#boxJson.version#.jar', manifest );
    }

    function lex( baseDir, boxJson ) {
        print.line( 'Creating lucee extension...' ).toConsole();

        print.indentedLine( 'Copying required jars...' ).toConsole();
        directoryCopy(
            baseDir & 'lib/',
            baseDir & 'dist/lex/jars/',
            false,
            ( p ) => boxJson.jars.dist.map( ( uri ) => uri.listLast( '/' ) ).find( getFileFromPath( p ) )
        );

        print.indentedLine( 'Copying admin components...' ).toConsole();
        directoryCopy( baseDir & 'build/context/', baseDir & 'dist/lex/context/', true );

        var manifest = {
            'Built-Date': dateTimeFormat( now(), 'yyyy-mm-dd hh:nn:ss' ),
            'version': '"#boxJson.version#"',
            'id': '"#boxJson.slug#"',
            'name': '"Redis driver"',
            'description': '"Free and open source, high-performance, distributed memory object caching system, generic in nature, but intended for use in speeding up dynamic web applications by alleviating database load."',
            'start-bundles': 'false',
            'release-type': 'server',
            'cache': '"[{''class'':''lucee.extension.io.cache.redis.simple.RedisCache'',''bundleName'':''redis.extension'',''bundleVersion'':''#boxJson.version#''},{''class'':''lucee.extension.io.cache.redis.sentinel.RedisSentinelCache'',''bundleName'':''redis.extension'',''bundleVersion'':''#boxJson.version#''}]"'
        };

        print.indentedLine( 'Zipping redis.extension-#boxJson.version#.lex' ).toConsole();
        jar( '#baseDir#dist/lex/', '#baseDir#dist/redis.extension-#boxJson.version#.lex', manifest );
    }


    private function prepare( baseDir ) {
        print.line( 'Ensure #baseDir#lib/ exists...' ).toConsole();
        directoryCreate( baseDir & 'lib/', true, true );

        print.line( 'Preparing to build to #baseDir#dist/ ...' ).toConsole();
        if ( directoryExists( baseDir & 'dist/' ) ) {
            directoryDelete( baseDir & 'dist/', true )
        }
        directoryCreate( baseDir & 'dist/classes/', true );
        directoryCreate( baseDir & 'dist/lex/jars/', true );
    }

    private function clean( baseDir ) {
        print.line( 'Cleaning up...' ).toConsole();
        for ( var d in [ 'classes', 'lex' ] ) {
            if ( directoryExists( baseDir & 'dist/#d#/' ) ) {
                directoryDelete( baseDir & 'dist/#d#/', true )
            }
        }
    }

    private function fetchJars( baseDir, allJars ) {
        print.line( 'Ensuring required jars exist...' ).toConsole();
        for ( var downloadURL in allJars ) {
            var targetPath = baseDir & 'lib/' & listLast( downloadURL, '/' );
            if ( !fileExists( targetPath ) ) {
                downloadFile( downloadURL, targetPath );
            }
        }
    }

    private function jar( string src, target, manifest ) {
        compress( 'zip', src, target, false );
        directoryCreate( 'zip://#target#!META-INF/', true, true );
        fileWrite( 'zip://#target#!META-INF/MANIFEST.MF', toManifestStr( manifest ) );
    }

    private function readBoxJson() {
        return deserializeJSON( fileRead( resolvePath( './box.json' ) ) );
    }

    private function requireBundle( boxJson ) {
        return boxJson.jars.dist
            .map( ( uri ) => {
                var jarPath = resolvePath( 'lib/' & uri.listLast( '/' ) )
                var manifest = manifestRead( jarPath );
                return '#manifest.main[ 'Bundle-SymbolicName' ]#;bundle-version=#manifest.main[ 'Bundle-Version' ]#';
            } )
            .toList();
    }

    private function toManifestStr( manifest ) {
        var lineReducer = ( r, k, v ) => {
            var l = '#k#: #v#';
            r.append( l.left( 70 ) );
            if ( l.len() > 70 ) {
                r.append(
                    l.mid( 71 )
                        .reMatch( '.{0,69}' )
                        .map( ( s ) => ' ' & s ),
                    true
                );
            }
            return r;
        };

        var manifestArr = manifest.reduce( lineReducer, [ ] );
        manifestArr.prepend( 'Manifest-Version: 1.0' );
        return manifestArr.toList( chr( 10 ) ) & chr( 10 );
    }

    private function downloadFile( downloadURL, targetPath ) {
        print.line( 'Downloading [#downloadURL#]' ).toConsole();
        try {
            progressableDownloader.download(
                downloadURL,
                targetPath,
                function( status ) {
                    progressBar.update( argumentCollection = status );
                }
            );
        } catch ( any var e ) {
            print.redLine( '#e.message##chr( 10 )##e.detail#' ).toConsole();
            if ( fileExists( targetPath ) ) {
                fileDelete( targetPath );
            }
        }
    }

}
