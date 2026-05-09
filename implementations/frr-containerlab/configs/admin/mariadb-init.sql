-- MariaDB Initialization for ESI Datacenter JupyterHub & SLURM
-- ==============================================================
-- Creates databases and users for JupyterHub and SLURM accounting
-- Run this on server-admin-01 during initialization

-- Create SLURM accounting database
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
USE slurm_acct_db;

-- Create SLURM user and grant privileges
CREATE USER IF NOT EXISTS 'slurm'@'192.168.50.%' IDENTIFIED BY 'slurm_pass';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'192.168.50.%';

-- SLURM accounting tables will be created by slurmdbd
-- No need to create them manually

-- Create JupyterHub database
CREATE DATABASE IF NOT EXISTS jupyterhub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE jupyterhub;

-- Create JupyterHub user and grant privileges
CREATE USER IF NOT EXISTS 'jupyterhub'@'192.168.50.%' IDENTIFIED BY 'jupyterhub_pass';
GRANT ALL PRIVILEGES ON jupyterhub.* TO 'jupyterhub'@'192.168.50.%';

-- Create oauth_state table for JupyterHub (optional, for future OAuth)
CREATE TABLE IF NOT EXISTS oauth_state (
  id INT AUTO_INCREMENT PRIMARY KEY,
  state_id VARCHAR(255) UNIQUE NOT NULL,
  oauth_code VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Flush privileges to apply changes
FLUSH PRIVILEGES;

-- Verify users are created
SELECT user, host FROM mysql.user WHERE user IN ('slurm', 'jupyterhub');
