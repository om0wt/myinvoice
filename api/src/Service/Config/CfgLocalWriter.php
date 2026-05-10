<?php

declare(strict_types=1);

namespace MyInvoice\Service\Config;

/**
 * Atomický merge a zápis do `cfg.local.php` v rootu repa.
 *
 * `cfg.local.php` je gitignored a `Config::load()` ho slévá přes `cfg.php`
 * pomocí `array_replace_recursive`. Hodí se pro per-instance overrides,
 * které se nastavují přes UI (instalační wizard, admin) a které nemá smysl
 * tlačit do hlavního `cfg.php` (zejména v Dockeru, kde je `cfg.php` jen
 * stub a všechno citlivé jde přes ENV).
 *
 * Použití:
 *   CfgLocalWriter::setKeys('/var/www/html', ['auth.require_totp' => true]);
 *
 * Bezpečnost:
 *   - Načte existující cfg.local.php (pokud je) jako pole, MERGE klíčů
 *     v dot notation, zapíše atomicky (LOCK_EX).
 *   - var_export má zaručený PHP-readable výstup, ale ztrácí komentáře
 *     v existujícím souboru. Pro hluboké manuální úpravy doporučujeme
 *     editovat `cfg.php` přímo.
 */
final class CfgLocalWriter
{
    /**
     * Nastaví hodnoty (dot notation klíče) v cfg.local.php a zapíše soubor.
     *
     * @param string                $rootDir  Absolutní cesta k repo rootu (kde leží cfg.php).
     * @param array<string,mixed>   $keys     Mapa "a.b.c" => hodnota.
     */
    public static function setKeys(string $rootDir, array $keys): void
    {
        $path = rtrim($rootDir, '/\\') . DIRECTORY_SEPARATOR . 'cfg.local.php';

        $existing = is_file($path) ? require $path : [];
        if (!is_array($existing)) {
            throw new \RuntimeException('cfg.local.php existuje, ale nevrací pole.');
        }

        foreach ($keys as $dotted => $value) {
            $existing = self::setByPath($existing, $dotted, $value);
        }

        $exported = var_export($existing, true);
        $contents = "<?php\n\n"
            . "// cfg.local.php — per-instance overrides (gitignored).\n"
            . "// Config::load() merguje tento soubor přes cfg.php pomocí array_replace_recursive.\n"
            . "// Soubor automaticky generuje setup wizard (CfgLocalWriter); ručně lze editovat.\n\n"
            . "return {$exported};\n";

        $bytes = file_put_contents($path, $contents, LOCK_EX);
        if ($bytes === false) {
            throw new \RuntimeException("cfg.local.php nelze zapsat na {$path} (zkontroluj práva souboru/adresáře).");
        }
    }

    /**
     * @param array<string,mixed> $data
     * @return array<string,mixed>
     */
    private static function setByPath(array $data, string $path, mixed $value): array
    {
        $segments = explode('.', $path);
        $ref      = &$data;
        foreach ($segments as $i => $segment) {
            if ($i === count($segments) - 1) {
                $ref[$segment] = $value;
                break;
            }
            if (!isset($ref[$segment]) || !is_array($ref[$segment])) {
                $ref[$segment] = [];
            }
            $ref = &$ref[$segment];
        }
        return $data;
    }
}
