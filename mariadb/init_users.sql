-- Script d'initialisation des utilisateurs et rôles MariaDB
-- À monter dans docker-entrypoint-initdb.d/ pour automatiser la création

-- 1. ADMIN
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED BY 'AdminPwd123!';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;

-- 2. APP_USER
CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY 'AppPwd123!';
GRANT CONNECT, SELECT, INSERT, UPDATE, DELETE ON *.* TO 'app_user'@'%';

-- 3. BACKUP (lecture seule)
CREATE USER IF NOT EXISTS 'backup_ro'@'%' IDENTIFIED BY 'BackupPwd123!';
GRANT CONNECT, SELECT ON *.* TO 'backup_ro'@'%';

-- 4. DEVELOPER
CREATE USER IF NOT EXISTS 'developer'@'%' IDENTIFIED BY 'DevPwd123!';
GRANT CREATE, USAGE ON *.* TO 'developer'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE ON *.* TO 'developer'@'%';

-- 5. BACKUP (par défaut pour tout autre utilisateur)
-- (optionnel, à dupliquer si besoin)
-- CREATE USER IF NOT EXISTS 'backup2'@'%' IDENTIFIED BY 'BackupPwd456!';
-- GRANT CONNECT, SELECT ON *.* TO 'backup2'@'%';

FLUSH PRIVILEGES;
