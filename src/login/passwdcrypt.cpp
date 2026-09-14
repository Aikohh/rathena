// Copyright (c) rAthena Dev Teams - Licensed under GNU GPL
// For more information, see LICENCE in the main folder

#include "passwdcrypt.hpp"

#include <cstdio>
#include <cstring>

#include <argon2.h>
#include <openssl/hmac.h>
#include <string>

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

static std::string passwd_pepper_value;

void passwd_set_pepper( const char* pepper ){
	passwd_pepper_value = ( pepper != nullptr ) ? pepper : "";
}

bool passwd_peppered( void ){
	return !passwd_pepper_value.empty();
}

/**
 * Apply the pepper, if one is set. HMAC rather than concatenation: it is the
 * construction designed for a secret key, and it sidesteps length-extension
 * and ambiguous-boundary issues entirely.
 *
 * The result is hex so it stays a printable C string for argon2.
 */
static std::string passwd_apply_pepper( const char* plain ){
	if( passwd_pepper_value.empty() ){
		return std::string( plain );
	}

	unsigned char mac[EVP_MAX_MD_SIZE];
	unsigned int mac_len = 0;

	HMAC( EVP_sha256(),
		passwd_pepper_value.data(), (int32)passwd_pepper_value.size(),
		(const unsigned char*)plain, strlen( plain ),
		mac, &mac_len );

	static const char hex[] = "0123456789abcdef";
	std::string out;

	out.reserve( mac_len * 2 );

	for( unsigned int i = 0; i < mac_len; i++ ){
		out.push_back( hex[mac[i] >> 4] );
		out.push_back( hex[mac[i] & 0x0F] );
	}

	return out;
}

std::string passwd_hash( const char* plain ){
	if( plain == nullptr ){
		return std::string();
	}

	// Bound the input even though callers pass a PASSWD_LENGTH buffer: this is
	// the single entry point for hashing and must not trust its caller.
	if( strlen( plain ) >= PASSWD_LENGTH ){
		ShowError( "passwd_hash: password too long (%zu >= %d).\n", strlen( plain ), PASSWD_LENGTH );
		return std::string();
	}

	// after this point `plain` may be the 64-character HMAC, not the password
	std::string peppered = passwd_apply_pepper( plain );

	plain = peppered.c_str();

	size_t plain_len = peppered.size();

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

static bool passwd_verify_with( const char* plain, const char* encoded, bool peppered ){
	if( plain == nullptr || encoded == nullptr || *encoded == '\0' ){
		return false;
	}

	std::string input = peppered ? passwd_apply_pepper( plain ) : std::string( plain );

	// argon2id_verify returns ARGON2_OK only on a match; every other code,
	// including a malformed hash, is a failure.
	return argon2id_verify( encoded, input.c_str(), input.size() ) == ARGON2_OK;
}

bool passwd_verify( const char* plain, const char* encoded ){
	return passwd_verify_with( plain, encoded, passwd_peppered() );
}

bool passwd_verify_raw( const char* plain, const char* encoded ){
	return passwd_verify_with( plain, encoded, false );
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
