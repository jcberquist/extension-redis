component {

    property name="progressableDownloader" inject="ProgressableDownloader";
    property name="progressBar" inject="ProgressBar";

    variables.bundleName = 'redis.cache.extension';
    variables.cacheClasses = [ 'extension.cache.redis.RedisCache', 'extension.cache.redis.RedisSentinelCache' ];

    function run() {
        var baseDir = resolvePath( './' ).replace( '\', '/', 'all' );
        var boxJson = readBoxJson();

        prepare( baseDir );
        compile( baseDir, boxJson );
        lex( baseDir, boxJson );
        clean( baseDir );

        print.greenLine( 'Extension is at dist/#bundleName#-#boxJson.version#.lex' ).toConsole();
        print.aquaLine( 'Cache classes:' )

        for ( var cache in expandCacheClasses( boxJson.version ) ) {
            for ( var key in cache ) {
                print.indentedAquaText( key & ': ' );
                print.greenLine( '''' & cache[ key ] & '''' );
            }
            print.line();
        }
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

        var cpSeparator = server.os.name.findNoCase( 'win' ) ? ';' : ':';

        command( '!javac' )
            .params( '-d', baseDir & 'dist/classes/' )
            .params( '-cp', allJars.map( ( p ) => 'lib/' & p.listLast( '/' ) ).toList( cpSeparator ) )
            .params( '-source', '1.8' )
            .params( '-target', '1.8' )
            .params( '-g:lines,vars,source' )
            .params( argumentCollection = javaFiles )
            .run();

        var manifest = {
            'Bundle-Version': '#boxJson.version#',
            'Built-Date': dateTimeFormat( now(), 'yyyy-mm-dd hh:nn:ss' ),
            'Bundle-Name': 'Redis Cache Extension',
            'Bundle-Description': 'Provides Redis cache support for Lucee 5.',
            'Bundle-SymbolicName': bundleName,
            'Export-Package': 'extension.cache.redis',
            'Bundle-ManifestVersion': '2',
            'Require-Bundle': requireBundle( boxJson )
        };

        print.line( 'Creating #bundleName#-#boxJson.version#.jar' ).toConsole();
        jar( '#baseDir#dist/classes/', '#baseDir#dist/lex/jars/#bundleName#-#boxJson.version#.jar', manifest );
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

        print.indentedLine( 'Copying extension image...' ).toConsole();
        directoryCreate( baseDir & 'dist/lex/META-INF/', true, true );
        fileCopy( baseDir & 'build/images/logo.png', baseDir & 'dist/lex/META-INF/logo.png' );

        var manifest = {
            'Built-Date': dateTimeFormat( now(), 'yyyy-mm-dd hh:nn:ss' ),
            'version': '"#boxJson.version#"',
            'id': '"#boxJson.slug#"',
            'name': '"Redis Cache Extension"',
            'description': '"Provides cache support for Redis. A fork of the official Lucee extension at [https://github.com/lucee/extension-redis]."',
            'start-bundles': 'false',
            'release-type': 'server',
            'cache': '"#serializeJSON( expandCacheClasses( boxJson.version ) ).replace( '"', '''', 'all' )#"'
        };

        print.indentedLine( 'Zipping #bundleName#-#boxJson.version#.lex' ).toConsole();
        jar( '#baseDir#dist/lex/', '#baseDir#dist/#bundleName#-#boxJson.version#.lex', manifest );
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

    private function expandCacheClasses( bundleVersion ) {
        return cacheClasses.map( ( cl ) => ( [ 'class': cl, 'bundleName': bundleName, 'bundleVersion': bundleVersion ] ) );
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
