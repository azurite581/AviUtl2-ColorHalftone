Texture2D<float4> src : register(t0);
SamplerState samp : register(s0);
cbuffer constant0 : register(b0) {
    float2 resolution;
    float aspect;
    float screen_size;
    float shape;
    float col1_dot_size;
    float col2_dot_size;
    float col3_dot_size;
    float2 col1_center_pos;
    float2 col2_center_pos;
    float2 col3_center_pos;
    float offset_type;
    float keep_orig_alpha;
    float fusion;
    float mixing_mode;
    float2 pad;
    float2x2 col1_screen_angle;
    float2x2 col1_dot_angle;
    float2x2 col2_screen_angle;
    float2x2 col2_dot_angle;
    float2x2 col3_screen_angle;
    float2x2 col3_dot_angle;
    float3 col1;
    float col1_visible;
    float3 col2;
    float col2_visible;
    float3 col3;
    float col3_visible;
    float4 bg_col;
}

// 2D SDF functions (https://iquilezles.org/articles/distfunctions2d/) by Inigo Quilez
// Copyright © 2020 Inigo Quilez
// Licensed under the MIT License.

float sdCircle(in float2 p, in float r)
{
    return length(p) - r;
}

float sdfSquare(in float2 p, in float2 size)
{
    float2 d = abs(p) - size;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdEquilateralTriangle(in float2 p, in float r)
{
    const float k = sqrt(3.0);
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if( p.x + k * p.y > 0.0 ) p = float2(p.x - k*p.y, -k * p.x - p.y) / 2.0;
    p.x -= clamp( p.x, -2.0 * r, 0.0 );
    return -length(p) * sign(p.y);
}

float sdPentagon(in float2 p, in float r)
{
    const float3 k = float3(0.809016994, 0.587785252, 0.726542528);
    p.x = abs(p.x);
    p -= 2.0 * min(dot(float2(-k.x, k.y), p), 0.0) * float2(-k.x, k.y);
    p -= 2.0 * min(dot(float2( k.x, k.y), p), 0.0) * float2( k.x, k.y);
    p -= float2(clamp(p.x, -r * k.z, r * k.z), r);
    return length(p) * sign(p.y);
}

float sdHexagon(in float2 p, in float r)
{
    const float3 k = float3(-0.866025404, 0.5, 0.577350269);
    p = abs(p);
    p -= 2.0 * min(dot(k.xy, p),0.0) * k.xy;
    p -= float2(clamp(p.x, -k.z * r, k.z * r), r);
    return length(p) * sign(p.y);
}

float sdfPentagram(in float2 p, in float r)
{
    // compile-time constants
    const float k1x = (sqrt(5.0) + 1.0           ) / 4.0;   // 0.809016994 = cos(pi/ 5)
    const float k2x = (sqrt(5.0) - 1.0           ) / 4.0;   // 0.309016994 = sin(pi/10)
    const float k1y = (sqrt(10.0 - 2.0 * sqrt(5.0))) / 4.0; // 0.587785252 = sin(pi/ 5)
    const float k2y = (sqrt(10.0 + 2.0 * sqrt(5.0))) / 4.0; // 0.951056516 = cos(pi/10)
    const float k1z = (sqrt( 5.0 - 2.0 * sqrt(5.0)));       // 0.726542528 = tan(pi/ 5) = k1y/k1x
    const float2 v1 = float2( k1x, -k1y);
    const float2 v2 = float2(-k1x, -k1y);
    const float2 v3 = float2( k2x, -k2y);

    // repeat domain 5x
    p.x = abs(p.x);
    p -= 2.0 * max(dot(v1,p), 0.0) * v1;
    p -= 2.0 * max(dot(v2,p), 0.0) * v2;
    p.x = abs(p.x);

    // draw edge
    p.y -= r;
    return length(p - v3 * clamp(dot(p,v3), 0.0, k1z * r)) // distance
           * sign(p.y * v3.x - p.x * v3.y);                // sign
}

float dot2(in float2 v) { return dot(v, v); }

float sdHeart(in float2 p)
{
    p.x = abs(p.x);

    if(p.y + p.x > 1.0)
        return sqrt(dot2(p - float2(0.25, 0.75))) - sqrt(2.0) / 4.0;
    return sqrt(min(dot2(p - float2(0.00, 1.00)),
                    dot2(p - 0.5 * max(p.x + p.y,0.0)))) * sign(p.x - p.y);
}

float3 rgb2cmy(in float3 rgb)
{
    return float3(1.0, 1.0, 1.0) - rgb;
}

float smoothThreshold(in float shape_size, in float max_shape_size, in float w, in float d)
{
    float t = smoothstep(0.0, max_shape_size, shape_size);
    float edge1 = lerp(0.0, w, t);
    float edge0 = -w;
    return smoothstep(edge0, edge1, d);
}

// Polynomial smooth minimum by iq
float smin(float a, float b, float k) {
    if (k <= 0.0) return min(a, b);
    float h = clamp(0.5 + 0.5 * (b-a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float4 halftone(in float2 p, in int channel, in float dot_size, in float2 center_pos, in float2x2 screen_angle, in float2x2 dot_angle, in float3 dot_col_, in float use_offset)
{
    static const float s = 1.0;  // 周期
    float4 dot_col = float4(dot_col_, 1.0);

    float2 tone_shift = center_pos / resolution.x * screen_size;
    float2 st = p - tone_shift;
    st = mul(screen_angle, st);

    float2 id = round(st / s);

    float min_d = 1e20;
    float size = 0.0;
    float shape_size = 0.0;
    int search_range = (int)ceil(dot_size * 1.5 + fusion * 0.5);
    search_range = clamp(search_range, 1, 3);
    for(int y = -search_range; y <= search_range; y++)
    for(int x = -search_range; x <= search_range; x++)
    {
        float2 rid = id + float2(x, y);
        float2 pos_in_st = rid * s;

        // 行が奇数の場合に X を 0.5 ずらして段違いに配置
        if (use_offset > 0.5) {
            if (fmod(abs(rid.y), 2.0) > 0.5) {
                pos_in_st.x += 0.5 * s;
            }
        }

        float2 r = st - pos_in_st;
        r = mul(dot_angle, r);

        // テクスチャサンプリング座標の計算
        float2 tex_uv = mul(transpose(screen_angle), pos_in_st);
        tex_uv += tone_shift;
        float2 center_uv = tex_uv / screen_size;

        tex_uv = float2(center_uv.x + 0.5, center_uv.y * aspect + 0.5);
        float4 tex_col = src.Sample(samp, tex_uv);

        // 透明な部分を背景色として扱う
        float3 tex_rgb = lerp(bg_col.rgb, tex_col.rgb, tex_col.a);
        tex_rgb = (mixing_mode > 0.5) ? tex_rgb : rgb2cmy(tex_rgb);

        float value = 0.0;
        switch (channel) {
            case 0: value = tex_rgb.r; break;
            case 1: value = tex_rgb.g; break;
            case 2: value = tex_rgb.b; break;
            default: value = tex_rgb.r; break;
        }

        value = clamp(value, 0.0, 1.0);
        if (mixing_mode > 0.5) value = pow(value, 2.2);  // 加法混色の場合は Linear sRGB にする
        size = sqrt(value) * 0.5 * s;

        float d = 1e20;
        switch (shape) {
            case 0:  // 円
            {
                static const float SCALE_FACTOR = 1.14;  // 微調整用の係数
                static const float CURVE_WEIGHT = 6.0;
                static const float BASE_SCALE = 1.128379167 * SCALE_FACTOR;  // タイルと内接するドットの面積比の平方根
                static const float MAX_SCALE = 1.414213562;  // ドットがタイルの四隅まで届くようにするための倍率
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdCircle(r, dot_size * size);
                break;
            }
            case 1:  // 四角形
            {
                static const float SCALE_FACTOR = 1.14;
                static const float CURVE_WEIGHT = 2.2;
                static const float BASE_SCALE = 1.0 * SCALE_FACTOR;
                static const float MAX_SCALE = 1.414213562;
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdfSquare(r, float2(dot_size * size, dot_size * size));
                break;
            }
            case 2:  // 三角形
            {
                static const float SCALE_FACTOR = 1.03;
                static const float CURVE_WEIGHT = 2.2;
                static const float BASE_SCALE = 1.519539404 * SCALE_FACTOR;
                static const float MAX_SCALE = 2.309401077;  //  = 4.0 / sqrt(3.0) = 高さがタイルの 2 倍になるようにする
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdEquilateralTriangle(r, size * dot_size);
                break;
            }
            case 3:  // 五角形
            {
                static const float SCALE_FACTOR = 1.1;
                static const float CURVE_WEIGHT = 4.0;
                static const float BASE_SCALE = 1.049727762 * SCALE_FACTOR;
                static const float MAX_SCALE = 1.414213562;
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdPentagon(r, size * dot_size);
                break;
            }
            case 4:  // 六角形
            {
                static const float SCALE_FACTOR = 1.1;
                static const float CURVE_WEIGHT = 4.0;
                static const float BASE_SCALE = 1.074585693 * SCALE_FACTOR;
                static const float MAX_SCALE = 1.414213562;
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdHexagon(r, size * dot_size);
                break;
            }
            case 5:  // 星形
            {
                static const float CURVE_WEIGHT = 2.2;
                static const float BASE_SCALE = 1.8;
                static const float MAX_SCALE = 3.0;
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdfPentagram(r, size * dot_size);
                break;
            }
            case 6:  // ハート
            {
                static const float CURVE_WEIGHT = 2.0;
                static const float BASE_SCALE = 2.3;
                static const float MAX_SCALE = 2.8;
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                float current_size = size * dot_size;

                d = (current_size < 1e-6) ?
                    1.0 :
                    sdHeart(float2((r / current_size).x, (r / current_size).y + 0.5)) * current_size;
                break;
            }
            case 7:  // 線
            {
                static const float SMOOTHNESS_FACTOR = 0.32;
                value += smoothstep(1.0 - SMOOTHNESS_FACTOR, 1.0 + SMOOTHNESS_FACTOR, value);
                float line_size = sqrt(value) * 0.5 * s;
                d = sdfSquare(r, float2(0.5 * s * dot_size * (1.0 + (1.0 / resolution.x * screen_size) * 2.0), line_size * dot_size));
                break;
            }
            default:
            {
                static const float SCALE_FACTOR = 1.14;
                static const float CURVE_WEIGHT = 6.0;
                static const float BASE_SCALE = 1.128379167 * SCALE_FACTOR;
                static const float MAX_SCALE = 1.414213562;
                float t = pow(value, CURVE_WEIGHT);
                size *= lerp(BASE_SCALE, MAX_SCALE, t);
                d = sdCircle(r, dot_size * size);
                break;
            }
        }

        if (d < min_d) {
            shape_size = size;
        }
        min_d = smin(min_d, d, fusion);
    }

    // アンチエイリアス
    float aa_width = length(float2(ddx(st.x), ddy(st.x)));
    float blend = 0.0;
    if (shape == 7) {
        blend = smoothThreshold(shape_size * dot_size, 0.5 * s, aa_width, min_d);
    } else {
        static const float AA_WIDTH_FACTOR = 1.2;
        blend = smoothstep(-aa_width, aa_width, min_d);
        float opacity = smoothstep(0.0, aa_width * AA_WIDTH_FACTOR, shape_size * dot_size);
        blend = 1.0 - (1.0 - blend) * opacity;
    }

    return lerp(dot_col, float4(bg_col.rgb, 0.0), blend);
}

float4 psmain(float4 pos : SV_Position) : SV_Target
{
    float2 uv = (pos.xy - 0.5 * resolution.xy) / resolution.x;
    float tex_alpha = src.Sample(samp, float2(uv.x + 0.5, uv.y * aspect + 0.5)).a;

    uv *= screen_size;

    float4 c = halftone(uv, 0, col1_dot_size, col1_center_pos, col1_screen_angle, col1_dot_angle, col1, offset_type);
    float4 m = halftone(uv, 1, col2_dot_size, col2_center_pos, col2_screen_angle, col2_dot_angle, col2, offset_type);
    float4 y = halftone(uv, 2, col3_dot_size, col3_center_pos, col3_screen_angle, col3_dot_angle, col3, offset_type);

    c = (col1_visible == 1) ? c : float4(bg_col.rgb, 0.0);
    m = (col2_visible == 1) ? m : float4(bg_col.rgb, 0.0);
    y = (col3_visible == 1) ? y : float4(bg_col.rgb, 0.0);

    float3 blended_rgb = (mixing_mode > 0.5) ? max(max(c.rgb, m.rgb), y.rgb) : min(min(c.rgb, m.rgb), y.rgb);
    float dot_alpha = max(max(c.a, m.a), y.a);

    float3 final_rgb = blended_rgb - bg_col.rgb * (1.0 - bg_col.a) * (1.0 - dot_alpha);
    final_rgb = saturate(final_rgb);

    float final_alpha = dot_alpha + bg_col.a * (1.0 - dot_alpha);
    final_alpha = saturate(final_alpha);

    final_rgb = (keep_orig_alpha > 0.5) ? final_rgb * tex_alpha : final_rgb;
    final_alpha = (keep_orig_alpha > 0.5) ? final_alpha * tex_alpha : final_alpha;

    return float4(final_rgb, final_alpha);
}
