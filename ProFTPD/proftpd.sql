-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1:3306
-- Tempo de geração: 02/05/2025 às 00:01
-- Versão do servidor: 8.0.41-0ubuntu0.24.04.1
-- Versão do PHP: 8.2.28

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Banco de dados: `proftpd`
--

-- --------------------------------------------------------

--
-- Estrutura para tabela `ftpgroup`
--

CREATE TABLE `ftpgroup` (
  `id` int NOT NULL,
  `groupname` varchar(16) NOT NULL,
  `gid` int NOT NULL,
  `members` varchar(16) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

-- --------------------------------------------------------

--
-- Estrutura para tabela `ftpquotalimits`
--

CREATE TABLE `ftpquotalimits` (
  `id` int NOT NULL,
  `name` varchar(30) NOT NULL,
  `quota_type` varchar(256) NOT NULL DEFAULT 'user',
  `per_session` varchar(256) NOT NULL DEFAULT 'false',
  `limit_type` varchar(256) NOT NULL DEFAULT 'hard',
  `bytes_in_avail` bigint NOT NULL DEFAULT '0',
  `bytes_out_avail` bigint NOT NULL DEFAULT '0',
  `bytes_xfer_avail` bigint UNSIGNED NOT NULL DEFAULT '0',
  `files_in_avail` bigint UNSIGNED NOT NULL DEFAULT '0',
  `files_out_avail` bigint UNSIGNED NOT NULL DEFAULT '0',
  `files_xfer_avail` bigint UNSIGNED NOT NULL DEFAULT '0'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

-- --------------------------------------------------------

--
-- Estrutura para tabela `ftpquotatallies`
--

CREATE TABLE `ftpquotatallies` (
  `id` int NOT NULL,
  `name` varchar(30) NOT NULL DEFAULT '',
  `quota_type` varchar(256) NOT NULL DEFAULT 'user',
  `bytes_in_used` bigint NOT NULL DEFAULT '0',
  `bytes_out_used` bigint NOT NULL DEFAULT '0',
  `bytes_xfer_used` bigint UNSIGNED NOT NULL DEFAULT '0',
  `files_in_used` bigint UNSIGNED NOT NULL DEFAULT '0',
  `files_out_used` bigint UNSIGNED NOT NULL DEFAULT '0',
  `files_xfer_used` bigint UNSIGNED NOT NULL DEFAULT '0'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

-- --------------------------------------------------------

--
-- Estrutura para tabela `ftpuser`
--

CREATE TABLE `ftpuser` (
  `id` int NOT NULL,
  `userid` varchar(60) NOT NULL,
  `passwd` varchar(32) NOT NULL,
  `uid` smallint NOT NULL,
  `gid` smallint NOT NULL,
  `homedir` varchar(255) NOT NULL,
  `shell` varchar(16) NOT NULL DEFAULT '/sbin/nologin',
  `count` int NOT NULL DEFAULT '0',
  `accessed` datetime NOT NULL,
  `modified` datetime NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

--
-- Índices para tabelas despejadas
--

--
-- Índices de tabela `ftpgroup`
--
ALTER TABLE `ftpgroup`
  ADD PRIMARY KEY (`id`);

--
-- Índices de tabela `ftpquotalimits`
--
ALTER TABLE `ftpquotalimits`
  ADD PRIMARY KEY (`id`);

--
-- Índices de tabela `ftpquotatallies`
--
ALTER TABLE `ftpquotatallies`
  ADD PRIMARY KEY (`id`);

--
-- Índices de tabela `ftpuser`
--
ALTER TABLE `ftpuser`
  ADD PRIMARY KEY (`id`);

--
-- AUTO_INCREMENT para tabelas despejadas
--

--
-- AUTO_INCREMENT de tabela `ftpgroup`
--
ALTER TABLE `ftpgroup`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `ftpquotalimits`
--
ALTER TABLE `ftpquotalimits`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `ftpquotatallies`
--
ALTER TABLE `ftpquotatallies`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `ftpuser`
--
ALTER TABLE `ftpuser`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
