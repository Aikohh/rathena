// Copyright (c) rAthena Dev Teams - Licensed under GNU GPL
// For more information, see LICENCE in the main folder

#include "passwdcrypt.hpp"

#include <cstdio>
#include <cstring>

#include <argon2.h>

#include <common/cbasetypes.hpp>
#include <common/mmo.hpp>
#include <common/showmsg.hpp>

#if defined(WIN32)
	#include <windows.h>
	#include <bcrypt.h>
	#pragma comment(lib, "bcrypt.lib")
#else
	#include <errno.h>
	#include <fcntl.h>
	#include <unistd.h>
	#if defined(__linux__)
		#include <sys/random.h>
	#endif
#endif

/**
 * Fill a buffer from the operating system entropy source.
 *
 * Deliberately NOT rnd_value(): that is the shared MT19937 generator, whose
 * state is recoverable from ~624 outputs. The login-server hands raw output
 * from it to anyone who asks, because MD5_Salt fills `md5key` with it and
 * AC_ACK_HASH sends those bytes to the client. Deriving password salts from
 * the same generator would let an attacker harvest md5key values, recover the
 * state, and predict future salts.
 *
 * std::random_device is not used either: the standard only requires it to be
 * non-deterministic, and some libstdc++ builds returned a fixed sequence.
 *
 * @return false if the OS could not supply the bytes; the caller must abort
 */
static bool passwd_random_bytes( unsigned char* out, size_t len ){
#if defined(WIN32)
	NTSTATUS rc = BCryptGenRandom( nullptr, out, (ULONG)len, BCRYPT_USE_SYSTEM_PREFERRED_RNG );

	if( !BCRYPT_SUCCESS( rc ) ){
		ShowError( "passwd_random_bytes: BCryptGenRandom failed (0x%08lx).\n", (unsigned long)rc );
		return false;
	}

	return true;
#else
	size_t done = 0;

	#if defined(__linux__)
	while( done < len ){
		ssize_t n = getrandom( out + done, len - done, 0 );

		if( n < 0 ){
			if( errno == EINTR ){
				continue;
			}

			break; // fall through to /dev/urandom
		}

		done += (size_t)n;
	}

	if( done == len ){
		return true;
	}
	#endif

	// portable fallback, and the primary path on non-Linux unix
	int32 fd = open( "/dev/urandom", O_RDONLY );

	if( fd < 0 ){
		ShowError( "passwd_random_bytes: cannot open /dev/urandom: %s\n", strerror( errno ) );
		return false;
	}

	while( done < len ){
		ssize_t n = read( fd, out + done, len - done );

		if( n <= 0 ){
			if( n < 0 && errno == EINTR ){
				continue;
			}

			close( fd );
			ShowError( "passwd_random_bytes: short read from /dev/urandom.\n" );
			return false;
		}

		done += (size_t)n;
	}

	close( fd );

	return true;
#endif
}

std::string passwd_hash( const char* plain ){
	if( plain == nullptr ){
		return std::string();
	}

	size_t plain_len = strlen( plain );

	// Bound the input even though callers pass a PASSWD_LENGTH buffer: this is
	// the single entry point for hashing and must not trust its caller.
	if( plain_len >= PASSWD_LENGTH ){
		ShowError( "passwd_hash: password too long (%zu >= %d).\n", plain_len, PASSWD_LENGTH );
		return std::string();
	}

	unsigned char salt[PASSWD_ARGON2_SALT];

	if( !passwd_random_bytes( salt, sizeof( salt ) ) ){
		ShowError( "passwd_hash: no entropy available, refusing to hash.\n" );
		return std::string();
	}

	char encoded[PASSWD_ARGON2_ENCODED + 1];

	int32 rc = argon2id_hash_encoded(
		PASSWD_ARGON2_TIME, PASSWD_ARGON2_MEMORY, PASSWD_ARGON2_LANES,
		plain, plain_len,
		salt, sizeof( salt ),
		PASSWD_ARGON2_HASH,
		encoded, sizeof( encoded )
	);

	if( rc != ARGON2_OK ){
		ShowError( "passwd_hash: argon2id failed: %s\n", argon2_error_message( rc ) );
		return std::string();
	}

	return std::string( encoded );
}

bool passwd_verify( const char* plain, const char* encoded ){
	if( plain == nullptr || encoded == nullptr || *encoded == '\0' ){
		return false;
	}

	// argon2id_verify returns ARGON2_OK only on a match; every other code,
	// including a malformed hash, is a failure.
	return argon2id_verify( encoded, plain, strlen( plain ) ) == ARGON2_OK;
}

bool passwd_is_argon2( const char* stored ){
	if( stored == nullptr ){
		return false;
	}

	return strncmp( stored, PASSWD_ARGON2_PREFIX, sizeof( PASSWD_ARGON2_PREFIX ) - 1 ) == 0;
}

bool passwd_is_md5( const char* stored ){
	if( stored == nullptr || strlen( stored ) != 32 ){
		return false;
	}

	// Checking for hex matters: PASSWD_LENGTH permits a 32-character plaintext
	// password, and length alone would misclassify it as MD5 and lock the user
	// out.
	for( const char* c = stored; *c != '\0'; c++ ){
		if( !( ( *c >= '0' && *c <= '9' ) || ( *c >= 'a' && *c <= 'f' ) || ( *c >= 'A' && *c <= 'F' ) ) ){
			return false;
		}
	}

	return true;
}
