<?php
/**
 * Plugin Name: Pressillion Health
 * Description: Platform health and connectivity checks for Pressillion-managed sites.
 */

if (!defined('ABSPATH')) {
    exit;
}

function pressillion_health_config() {

    $websiteId = getenv('WEBSITE_ID');
    $secret = getenv('PRESSILLION_PING_SECRET');

    return [
        'website_id' => is_string($websiteId) ? (int)$websiteId : 0,
        'secret' => is_string($secret) ? trim($secret) : '',
    ];

}

function pressillion_health_sign($ts, $websiteId, $secret) {

    return hash_hmac('sha256', $ts . '|' . $websiteId, $secret);

}

add_action('rest_api_init', function () {

    register_rest_route('pressillion/v1', '/health', [
        'methods' => 'GET',
        'permission_callback' => '__return_true',
        'callback' => function (\WP_REST_Request $request) {

            $cfg = pressillion_health_config();

            if ($cfg['website_id'] <= 0 || $cfg['secret'] === '') {
                return new \WP_REST_Response([
                    'ok' => false,
                    'error' => 'Health check not configured',
                ], 500);
            }

            $ts  = (string)$request->get_param('ts');
            $sig = (string)$request->get_param('sig');

            if ($ts === '' || $sig === '') {
                return new \WP_REST_Response([
                    'ok' => false,
                    'error' => 'Missing parameters',
                ], 401);
            }

            // 5-minute validity window
            $now   = time();
            $tsInt = (int)$ts;

            if ($tsInt <= 0 || abs($now - $tsInt) > 300) {
                return new \WP_REST_Response([
                    'ok' => false,
                    'error' => 'Expired request',
                ], 401);
            }

            $expected = pressillion_health_sign(
                $ts,
                $cfg['website_id'],
                $cfg['secret']
            );

            if (!hash_equals($expected, $sig)) {
                return new \WP_REST_Response([
                    'ok' => false,
                    'error' => 'Invalid signature',
                ], 401);
            }

            return new \WP_REST_Response([
                'ok'         => true,
                'website_id' => $cfg['website_id'],
                'wordpress'  => get_bloginfo('version'),
                'php'        => PHP_VERSION,
                'time'       => gmdate('c'),
            ], 200);

        },
    ]);

});