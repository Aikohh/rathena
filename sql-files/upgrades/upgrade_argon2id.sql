-- Argon2id password hashing.
--
-- `passwd_type` records how `user_pass` is stored (see enum e_passwd_type):
--   0 = legacy plaintext or a 32-character MD5 hex digest
--   1 = argon2id( password )
--   2 = argon2id( MD5( password ) ), for rows migrated from use_MD5_passwords
--
-- Existing rows stay at 0 and are rehashed on their owner's next successful
-- login, or in bulk with `./login-server --encrypt-passwords`.
--
-- 98 characters is argon2_encodedlen() at m=19456, t=2, p=1 with a 16-byte
-- salt and a 32-byte digest.
ALTER TABLE `login`
	ADD COLUMN `passwd_type` tinyint unsigned NOT NULL default 0,
	MODIFY `user_pass` VARCHAR(98) NOT NULL default ''
;
