#version 450

#extension GL_ARB_fragment_shader_interlock : enable
#extension GL_EXT_nonuniform_qualifier : enable

layout(location = 0) in vec4 TexCoord;
layout(location = 1) in vec4 TexCoord2;

layout(location = 0) out vec4 fragColor;

// bindless texture array
layout(binding = 0) uniform sampler2D	textures[8];

layout(binding = 1, input_attachment_index = 0) uniform subpassInput background;

const uint PLANE0 = 0;
const uint PLANE1 = 1;
const uint PLANE2 = 2;
const uint PLANE3 = 3;
const uint LOCAL_KEY = 4;
const uint LAYER_KEY = 5;

const uint is_straight_alpha_mask = 1u << 0;
const uint has_local_key_mask = 1u << 1;
const uint has_layer_key_mask = 1u << 2;
const uint invert_mask = 1u << 3;
const uint levels_mask = 1u << 4;
const uint csb_mask = 1u << 5;
const uint chroma_mask = 1u << 6;
const uint chroma_show_mask_mask = 1u << 7;
const uint cdl_mask = 1u << 8;
const uint white_balance_mask = 1u << 9;
const uint lift_midtone_gain_mask = 1u << 10;
const uint hue_shift_mask = 1u << 11;
const uint tone_balance_mask = 1u << 12;
const uint split_tone_mask = 1u << 13;

layout(push_constant) uniform ParamsBlock {
    uint color_space_index;
    float precision_factor[4];
    int blend_mode;
    int keyer;
    int pixel_format;
    float opacity;

/* levels */
    float min_input;
    float max_input;
    float gamma;
    float min_output;
    float max_output;
    
/* contrast, saturation & brightness */
    float brt;
    float sat;
    float con;

/* Chroma */
    float chroma_target_hue;
    float chroma_hue_width;
    float chroma_min_saturation;
    float chroma_min_brightness;
    float chroma_softness;
    float chroma_spill_suppress;
    float chroma_spill_suppress_saturation;

    uint flags;

#ifndef CASPAR_NO_GRADING
/* Primary grading. Built without it (CASPAR_NO_GRADING) the block ends at flags, for devices whose
   push constants cannot hold all of it. Per-channel values are float[3], not vec3: push constants
   use std430, where a vec3 aligns to 16 bytes and would no longer match uniform_block. */
    float cdl_slope[3];
    float cdl_offset[3];
    float cdl_power[3];
    float cdl_saturation;
    float wb_temperature;
    float wb_tint;
    float lmg_lift[3];
    float lmg_midtone[3];
    float lmg_gain[3];
    float hue_shift_degrees;
    float tb_shadows;
    float tb_highlights;
    float split_shadow_color[3];
    float split_highlight_color[3];
    float split_balance;
#endif
};

// Each matrix follows from its luma coefficients: Cr->R is 2(1-Kr), Cb->B is 2(1-Kb),
// and the green terms are -2(1-Kb)Kb/Kg and -2(1-Kr)Kr/Kg. BT.601's Cr->G was -0.509
// and should be -0.714136 = -2(1-0.299)(0.299)/0.587. Kept in step with the OpenGL
// mixer, which carried the same wrong literal.
const mat3[3] color_matrices = mat3[3](
                    mat3(1.0, 0.0, 1.402, 1.0, -0.344136, -0.714136, 1.0, 1.772, 0.0),
                    mat3(1.0, 0.0, 1.5748, 1.0, -0.1873, -0.4681, 1.0, 1.8556, 0.0),
                    mat3(1.0, 0.0, 1.4746, 1.0, -0.16455312684366, -0.57135312684366, 1.0, 1.8814, 0.0)
                ); 
const vec3[3] luma_coefficients = vec3[3](
                    vec3(0.299, 0.587, 0.114), // Rec. 601
                    vec3(0.2126, 0.7152, 0.0722),  // Rec. 709
                    vec3(0.2627, 0.6780, 0.0593)   // Rec. 2020
                );

/*
** Contrast, saturation, brightness
** Code of this function is from TGM's shader pack
** http://irrlicht.sourceforge.net/phpBB2/viewtopic.php?t=21057
*/

vec3 ContrastSaturationBrightness(vec4 color, float brt, float sat, float con)
{
    vec3 luma_coeff = luma_coefficients[color_space_index];
    
    const float AvgLumR = 0.5;
    const float AvgLumG = 0.5;
    const float AvgLumB = 0.5;

    if (color.a > 0.0)
        color.rgb /= color.a;

    vec3 AvgLumin = vec3(AvgLumR, AvgLumG, AvgLumB);
    vec3 brtColor = color.rgb * brt;
    vec3 intensity = vec3(dot(brtColor, luma_coeff));
    vec3 satColor = mix(intensity, brtColor, sat);
    vec3 conColor = mix(AvgLumin, satColor, con);

    conColor.rgb *= color.a;

    return conColor;
}

/*
** Gamma correction
** Details: http://blog.mouaif.org/2009/01/22/photoshop-gamma-correction-shader/
*/
#define GammaCorrection(color, gamma)								pow(color, vec3(1.0 / gamma))

/*
** Levels control (input (+gamma), output)
** Details: http://blog.mouaif.org/2009/01/28/levels-control-shader/
*/

#define LevelsControlInputRange(color, minInput, maxInput)				min(max(color - vec3(minInput), vec3(0.0)) / (vec3(maxInput) - vec3(minInput)), vec3(1.0))
#define LevelsControlInput(color, minInput, gamma, maxInput)				GammaCorrection(LevelsControlInputRange(color, minInput, maxInput), gamma)
#define LevelsControlOutputRange(color, minOutput, maxOutput) 			mix(vec3(minOutput), vec3(maxOutput), color)
#define LevelsControl(color, minInput, gamma, maxInput, minOutput, maxOutput) 	LevelsControlOutputRange(LevelsControlInput(color, minInput, gamma, maxInput), minOutput, maxOutput)

/*
** Photoshop & misc math
** Blending modes, RGB/HSL/Contrast/Desaturate, levels control
**
** Romain Dura | Romz
** Blog: http://blog.mouaif.org
** Post: http://blog.mouaif.org/?p=94
*/


/*
** Desaturation
*/

vec4 Desaturate(vec3 color, float Desaturation)
{
    vec3 grayXfer = vec3(0.3, 0.59, 0.11);
    vec3 gray = vec3(dot(grayXfer, color));
    return vec4(mix(color, gray, Desaturation), 1.0);
}


/*
** Hue, saturation, luminance
*/

vec3 RGBToHSL(vec3 color)
{
    vec3 hsl;

    float fmin = min(min(color.r, color.g), color.b);
    float fmax = max(max(color.r, color.g), color.b);
    float delta = fmax - fmin;

    hsl.z = (fmax + fmin) / 2.0;

    if (delta == 0.0)
    {
        hsl.x = 0.0;
        hsl.y = 0.0;
    }
    else
    {
        if (hsl.z < 0.5)
            hsl.y = delta / (fmax + fmin);
        else
            hsl.y = delta / (2.0 - fmax - fmin);

        float deltaR = (((fmax - color.r) / 6.0) + (delta / 2.0)) / delta;
        float deltaG = (((fmax - color.g) / 6.0) + (delta / 2.0)) / delta;
        float deltaB = (((fmax - color.b) / 6.0) + (delta / 2.0)) / delta;

        if (color.r == fmax )
            hsl.x = deltaB - deltaG;
        else if (color.g == fmax)
            hsl.x = (1.0 / 3.0) + deltaR - deltaB;
        else if (color.b == fmax)
            hsl.x = (2.0 / 3.0) + deltaG - deltaR;

        if (hsl.x < 0.0)
            hsl.x += 1.0;
        else if (hsl.x > 1.0)
            hsl.x -= 1.0;
    }

    return hsl;
}

float HueToRGB(float f1, float f2, float hue)
{
    if (hue < 0.0)
        hue += 1.0;
    else if (hue > 1.0)
        hue -= 1.0;
    float res;
    if ((6.0 * hue) < 1.0)
        res = f1 + (f2 - f1) * 6.0 * hue;
    else if ((2.0 * hue) < 1.0)
        res = f2;
    else if ((3.0 * hue) < 2.0)
        res = f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0;
    else
        res = f1;
    return res;
}

vec3 HSLToRGB(vec3 hsl)
{
    vec3 rgb;

    if (hsl.y == 0.0)
        rgb = vec3(hsl.z);
    else
    {
        float f2;

        if (hsl.z < 0.5)
            f2 = hsl.z * (1.0 + hsl.y);
        else
            f2 = (hsl.z + hsl.y) - (hsl.y * hsl.z);

        float f1 = 2.0 * hsl.z - f2;

        rgb.r = HueToRGB(f1, f2, hsl.x + (1.0/3.0));
        rgb.g = HueToRGB(f1, f2, hsl.x);
        rgb.b= HueToRGB(f1, f2, hsl.x - (1.0/3.0));
    }

    return rgb;
}




/*
** Float blending modes
** Adapted from here: http://www.nathanm.com/photoshop-blending-math/
** But I modified the HardMix (wrong condition), Overlay, SoftLight, ColorDodge, ColorBurn, VividLight, PinLight (inverted layers) ones to have correct results
*/

#define BlendLinearDodgef 					BlendAddf
#define BlendLinearBurnf 					BlendSubstractf
#define BlendAddf(base, blend) 				min(base + blend, 1.0)
#define BlendSubstractf(base, blend) 		max(base + blend - 1.0, 0.0)
#define BlendLightenf(base, blend) 		max(blend, base)
#define BlendDarkenf(base, blend) 			min(blend, base)
#define BlendLinearLightf(base, blend) 	(blend < 0.5 ? BlendLinearBurnf(base, (2.0 * blend)) : BlendLinearDodgef(base, (2.0 * (blend - 0.5))))
#define BlendScreenf(base, blend) 			(1.0 - ((1.0 - base) * (1.0 - blend)))
#define BlendOverlayf(base, blend) 		(base < 0.5 ? (2.0 * base * blend) : (1.0 - 2.0 * (1.0 - base) * (1.0 - blend)))
#define BlendSoftLightf(base, blend) 		((blend < 0.5) ? (2.0 * base * blend + base * base * (1.0 - 2.0 * blend)) : (sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend)))
#define BlendColorDodgef(base, blend) 		((blend == 1.0) ? blend : min(base / (1.0 - blend), 1.0))
#define BlendColorBurnf(base, blend) 		((blend == 0.0) ? blend : max((1.0 - ((1.0 - base) / blend)), 0.0))
#define BlendVividLightf(base, blend)		((blend < 0.5) ? BlendColorBurnf(base, (2.0 * blend)) : BlendColorDodgef(base, (2.0 * (blend - 0.5))))
#define BlendPinLightf(base, blend) 		((blend < 0.5) ? BlendDarkenf(base, (2.0 * blend)) : BlendLightenf(base, (2.0 *(blend - 0.5))))
#define BlendHardMixf(base, blend) 		((BlendVividLightf(base, blend) < 0.5) ? 0.0 : 1.0)
#define BlendReflectf(base, blend) 		((blend == 1.0) ? blend : min(base * base / (1.0 - blend), 1.0))


/*
** Vector3 blending modes
*/

#define Blend(base, blend, funcf) 			vec3(funcf(base.r, blend.r), funcf(base.g, blend.g), funcf(base.b, blend.b))

#define BlendNormal(base, blend) 			(blend)
#define BlendLighten						BlendLightenf
#define BlendDarken						BlendDarkenf
#define BlendMultiply(base, blend) 		(base * blend)
#define BlendAverage(base, blend) 			((base + blend) / 2.0)
#define BlendAdd(base, blend) 				min(base + blend, vec3(1.0))
#define BlendSubstract(base, blend) 		max(base + blend - vec3(1.0), vec3(0.0))
#define BlendDifference(base, blend) 		abs(base - blend)
#define BlendNegation(base, blend) 		(vec3(1.0) - abs(vec3(1.0) - base - blend))
#define BlendExclusion(base, blend) 		(base + blend - 2.0 * base * blend)
#define BlendScreen(base, blend) 			Blend(base, blend, BlendScreenf)
#define BlendOverlay(base, blend) 			Blend(base, blend, BlendOverlayf)
#define BlendSoftLight(base, blend) 		Blend(base, blend, BlendSoftLightf)
#define BlendHardLight(base, blend) 		BlendOverlay(blend, base)
#define BlendColorDodge(base, blend) 		Blend(base, blend, BlendColorDodgef)
#define BlendColorBurn(base, blend) 		Blend(base, blend, BlendColorBurnf)
#define BlendLinearDodge					BlendAdd
#define BlendLinearBurn					BlendSubstract
#define BlendLinearLight(base, blend) 		Blend(base, blend, BlendLinearLightf)
#define BlendVividLight(base, blend) 		Blend(base, blend, BlendVividLightf)
#define BlendPinLight(base, blend) 		Blend(base, blend, BlendPinLightf)
#define BlendHardMix(base, blend) 			Blend(base, blend, BlendHardMixf)
#define BlendReflect(base, blend) 			Blend(base, blend, BlendReflectf)
#define BlendGlow(base, blend) 			BlendReflect(blend, base)
#define BlendPhoenix(base, blend) 			(min(base, blend) - max(base, blend) + vec3(1.0))
#define BlendOpacity(base, blend, F, O) 	(F(base, blend) * O + blend * (1.0 - O))


vec3 BlendHue(vec3 base, vec3 blend)
{
    vec3 baseHSL = RGBToHSL(base);
    return HSLToRGB(vec3(RGBToHSL(blend).r, baseHSL.g, baseHSL.b));
}

vec3 BlendSaturation(vec3 base, vec3 blend)
{
    vec3 baseHSL = RGBToHSL(base);
    return HSLToRGB(vec3(baseHSL.r, RGBToHSL(blend).g, baseHSL.b));
}

vec3 BlendColor(vec3 base, vec3 blend)
{
    vec3 blendHSL = RGBToHSL(blend);
    return HSLToRGB(vec3(blendHSL.r, blendHSL.g, RGBToHSL(base).b));
}

vec3 BlendLuminosity(vec3 base, vec3 blend)
{
    vec3 baseHSL = RGBToHSL(base);
    return HSLToRGB(vec3(baseHSL.r, baseHSL.g, RGBToHSL(blend).b));
}

// Chroma keying
// Author: Tim Eves <timseves@googlemail.com>
//
// This implements the Chroma key algorithm described in the paper:
//      'Software Chroma Keying in an Imersive Virtual Environment'
//      by F. van den Bergh & V. Lalioti
// but as a pixel shader algorithm.
//

// This allows us to implement the paper's alphaMap curve in software
// rather than a largeish array
float alpha_map(float d)
{
    return 1.0 - smoothstep(1.0, chroma_softness, d);
}

// http://stackoverflow.com/questions/15095909/from-rgb-to-hsv-in-opengl-glsl
vec3 rgb2hsv(vec3 c)
{
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// From the same page
vec3 hsv2rgb(vec3 c)
{
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float AngleDiff(float angle1, float angle2)
{
    return 0.5 - abs(abs(angle1 - angle2) - 0.5);
}

float AngleDiffDirectional(float angle1, float angle2)
{
    float diff = angle1 - angle2;

    return diff < -0.5
            ? diff + 1.0
            : (diff > 0.5 ? diff - 1.0 : diff);
}

float Distance(float actual, float target)
{
    return min(0.0, target - actual);
}

float ColorDistance(vec3 hsv)
{
    float hueDiff					= AngleDiff(hsv.x, chroma_target_hue) * 2;
    float saturationDiff			= Distance(hsv.y, chroma_min_saturation);
    float brightnessDiff			= Distance(hsv.z, chroma_min_brightness);

    float saturationBrightnessScore	= max(brightnessDiff, saturationDiff);
    float hueScore					= hueDiff - chroma_hue_width;

    return -hueScore * saturationBrightnessScore;
}

vec3 supress_spill(vec3 c)
{
    float hue		= c.x;
    float diff		= AngleDiffDirectional(hue, chroma_target_hue);
    float distance	= abs(diff) / chroma_spill_suppress;

    if (distance < 1)
    {
        c.x = diff < 0
                ? chroma_target_hue - chroma_spill_suppress
                : chroma_target_hue + chroma_spill_suppress;
        c.y *= min(1.0, distance + chroma_spill_suppress_saturation);
    }

    return c;
}

// Key on any color
vec4 ChromaOnCustomColor(vec4 c, bool show_mask)
{
    vec3 hsv		= rgb2hsv(c.rgb);
    float distance	= ColorDistance(hsv);
    float d			= distance * -2.0 + 1.0;
    vec4 suppressed	= vec4(hsv2rgb(supress_spill(hsv)), 1.0);
    float alpha		= alpha_map(d);

    suppressed *= alpha;

    return show_mask ? vec4(suppressed.a, suppressed.a, suppressed.a, 1) : suppressed;
}



vec3 get_blend_color(vec3 back, vec3 fore)
{
    switch(blend_mode)
    {
    case  0: return BlendNormal(back, fore);
    case  1: return BlendLighten(back, fore);
    case  2: return BlendDarken(back, fore);
    case  3: return BlendMultiply(back, fore);
    case  4: return BlendAverage(back, fore);
    case  5: return BlendAdd(back, fore);
    case  6: return BlendSubstract(back, fore);
    case  7: return BlendDifference(back, fore);
    case  8: return BlendNegation(back, fore);
    case  9: return BlendExclusion(back, fore);
    case 10: return BlendScreen(back, fore);
    case 11: return BlendOverlay(back, fore);
//	case 12: return BlendSoftLight(back, fore);
    case 13: return BlendHardLight(back, fore);
    case 14: return BlendColorDodge(back, fore);
    case 15: return BlendColorBurn(back, fore);
    case 16: return BlendLinearDodge(back, fore);
    case 17: return BlendLinearBurn(back, fore);
    case 18: return BlendLinearLight(back, fore);
    case 19: return BlendVividLight(back, fore);
    case 20: return BlendPinLight(back, fore);
    case 21: return BlendHardMix(back, fore);
    case 22: return BlendReflect(back, fore);
    case 23: return BlendGlow(back, fore);
    case 24: return BlendPhoenix(back, fore);
    // The HSL blends move a hue from one colour to another. A grey has none and is given zero, which
    // is red in this shader's RGB order and blue in the OpenGL mixer's BGR. Run them in BGR, as that
    // mixer does, so a grey gives the same colour in both; for any other colour the orders agree.
    case 25: return BlendHue(back.bgr, fore.bgr).bgr;
    case 26: return BlendSaturation(back.bgr, fore.bgr).bgr;
    case 27: return BlendColor(back.bgr, fore.bgr).bgr;
    case 28: return BlendLuminosity(back.bgr, fore.bgr).bgr;
    }
    return BlendNormal(back, fore);
}

vec4 blend(vec4 fore)
{
    // attachments have bgra format to match opengl accelerator
    vec4 back = subpassLoad(background).bgra;
    if(blend_mode != 0)
       fore.rgb = get_blend_color(back.rgb/(back.a+0.0000001), fore.rgb/(fore.a+0.0000001))*fore.a;
   switch(keyer)
   {
       case 1:  return fore + back; // additive
       default: return fore + (1.0-fore.a)*back; // linear
   }
}

vec4 ycbcra_to_rgba(float Y, float Cb, float Cr, float A)
{
    mat3 color_matrix = transpose(color_matrices[color_space_index]);

    const float luma_coefficient = 255.0/219.0;
    const float chroma_coefficient = 255.0/224.0;

    vec3 YCbCr = vec3(Y, Cb, Cr) * 255;
    YCbCr -= vec3(16.0, 128.0, 128.0);
    YCbCr *= vec3(luma_coefficient, chroma_coefficient, chroma_coefficient);

    return vec4(color_matrix * YCbCr / 255, A);
}

vec4 get_sample(sampler2D texSampler, vec2 coords)
{
    return texture(texSampler, coords);
}

vec4 get_rgba_color()
{
    vec2 uv = TexCoord.st / TexCoord.q;

    switch(pixel_format)
    {
    case 0:		//gray
        return vec4(get_sample(textures[PLANE0], uv).rrr * precision_factor[0], 1.0);
    case 1:		//bgra,
        return get_sample(textures[PLANE0], uv).bgra * precision_factor[0];
    case 2:		//rgba,
        return get_sample(textures[PLANE0], uv).rgba * precision_factor[0];
    // Packed formats. Textures here are uploaded as the bytes lie, so byte 0 is .r; the OpenGL mixer
    // uploads four-channel data as GL_BGRA, where byte 0 lands in .b, and its swizzles are written for
    // that. Copied as they were, they read ARGB with its alpha taken from blue and ABGR with red and
    // blue exchanged.
    case 3:		//argb,
        return get_sample(textures[PLANE0], uv).gbar * precision_factor[0];
    case 4:		//abgr,
        return get_sample(textures[PLANE0], uv).abgr * precision_factor[0];
    case 5:		//ycbcr,
        {
            float y  = get_sample(textures[PLANE0], uv).r * precision_factor[0];
            float cb = get_sample(textures[PLANE1], uv).r * precision_factor[1];
            float cr = get_sample(textures[PLANE2], uv).r * precision_factor[2];
            return ycbcra_to_rgba(y, cb, cr, 1.0);
        }
    case 6:		//ycbcra
        {
            float y  = get_sample(textures[PLANE0], uv).r * precision_factor[0];
            float cb = get_sample(textures[PLANE1], uv).r * precision_factor[1];
            float cr = get_sample(textures[PLANE2], uv).r * precision_factor[2];
            float a  = get_sample(textures[PLANE3], uv).r * precision_factor[3];
            return ycbcra_to_rgba(y, cb, cr, a);
        }
    case 7:		//luma
        {
            vec3 y3 = get_sample(textures[PLANE0], uv).rrr * precision_factor[0];
            return vec4((y3-0.065)/0.859, 1.0);
        }
    case 8:		//bgr,
        return vec4(get_sample(textures[PLANE0], uv).bgr * precision_factor[0], 1.0);
    case 9:		//rgb,
        return vec4(get_sample(textures[PLANE0], uv).rgb * precision_factor[0], 1.0);
	case 10:	// uyvy
		{
			// PLANE1 is the same bytes four to a texel, U Y0 V Y1, so Cb is .r and Cr is .b here. The
			// OpenGL mixer reads them from .b and .r because its GL_BGRA upload puts byte 0 in .b; the
			// copied swizzle exchanged Cb and Cr on every UYVY source, NDI and DeckLink capture among them.
			float y  = get_sample(textures[PLANE0], uv).g * precision_factor[0];
			float cb = get_sample(textures[PLANE1], uv).r * precision_factor[1];
			float cr = get_sample(textures[PLANE1], uv).b * precision_factor[1];
			return ycbcra_to_rgba(y, cb, cr, 1.0);
		}
    // This shader works in RGB order, as ycbcra_to_rgba above returns it. The OpenGL one works in
    // BGR (its ycbcra_to_rgba ends in .bgra), which is where vec4(b, g, r) came from: copied here,
    // it swapped red and blue on every planar RGB source, ProRes 4444 decoded on the CPU among them.
    case 11:    // gbrp
        {
            float g = get_sample(textures[PLANE0], uv).r * precision_factor[0];
            float b = get_sample(textures[PLANE1], uv).r * precision_factor[1];
            float r = get_sample(textures[PLANE2], uv).r * precision_factor[2];
            return vec4(r, g, b, 1.0);
        }
    case 12:    // gbrap
        {
            float g = get_sample(textures[PLANE0], uv).r * precision_factor[0];
            float b = get_sample(textures[PLANE1], uv).r * precision_factor[1];
            float r = get_sample(textures[PLANE2], uv).r * precision_factor[2];
            float a = get_sample(textures[PLANE3], uv).r * precision_factor[3];
            return vec4(r, g, b, a);
        }
    case 13:    // nv12
    case 14:    // p010
        {
            // Semi-planar: full-res luma in PLANE0.r, interleaved chroma in PLANE1.rg at
            // 4:2:0, 4:2:2 or 4:4:4. The sampler resolves any subsampling for us, so both
            // planes are read at the same normalised coordinate. p010 stores its 10 bits
            // in the high bits of a 16-bit texel, which R16_UNORM already normalises to
            // 0..1 — hence a precision_factor of 1 for both, unlike yuv420p10.
            float y  = get_sample(textures[PLANE0], uv).r * precision_factor[0];
            vec2  cbcr = get_sample(textures[PLANE1], uv).rg * precision_factor[1];
            return ycbcra_to_rgba(y, cbcr.r, cbcr.g, 1.0);
        }
    case 15:    // ayuv
        {
            // Packed A, Y, Cb, Cr: one texel per pixel, so the four land in r, g, b, a.
            vec4 ayuv = get_sample(textures[PLANE0], uv) * precision_factor[0];
            return ycbcra_to_rgba(ayuv.g, ayuv.b, ayuv.a, ayuv.r);
        }
    }
    return vec4(0.0, 0.0, 0.0, 0.0);
}

#ifndef CASPAR_NO_GRADING
// ============================ Primary grading chain ============================
//
// The same functions as the OpenGL mixer, in the same order, translated to this shader's channel
// order. The OpenGL colour vector is BGR (its ycbcra_to_rgba ends in .bgra), so its grading
// swizzles every per-channel value and every hue conversion with .bgr. This one is RGB, so those
// swizzles go: copied as they are, they would exchange red and blue in every per-channel control
// and turn every hue rotation into its negation. Greys are invariant under that exchange, so test
// with asymmetric per-channel values.
// ===============================================================================

vec3 rgb3(float v[3]) { return vec3(v[0], v[1], v[2]); }

float working_luma(vec3 c) { return dot(c, luma_coefficients[color_space_index]); }

// ---- White Balance ----
// temp: -1=cool (blue), +1=warm (orange); tint_val: -1=magenta, +1=green.
// Diagonal gain matrix, no clamping so HDR headroom is preserved.
vec3 apply_white_balance(vec3 c, float temp, float tint_val)
{
    vec3 gain_rgb = vec3(1.0 + temp     * 0.20,  // warm -> more red
                         1.0 + tint_val * 0.10,  // tint -> more green
                         1.0 - temp     * 0.20); // warm -> less blue
    return c * gain_rgb;
}

// ---- Lift / Midtone / Gain (3-way colour corrector) ----
// out = pow(max(c * gain + lift, 0.0), 1.0 / midtone). midtone is clamped before the reciprocal:
// see the OpenGL shader for why clamping the exponent afterwards cannot work.
vec3 apply_lmg(vec3 c, vec3 lift, vec3 midtone, vec3 gain)
{
    c = max(c * gain + lift, vec3(0.0));
    c = pow(c, 1.0 / clamp(midtone, vec3(0.01), vec3(100.0)));
    return c;
}

// ---- Hue Shift ----
// Rotate hue in HSV space. Extract peak luminance, normalise, rotate, re-scale
// so HDR values (>1.0) are preserved.
vec3 apply_hue_shift(vec3 c, float degrees)
{
    float peak = max(max(c.r, c.g), max(c.b, 0.0001));
    vec3  norm = c / peak;
    vec3  hsv  = rgb2hsv(clamp(norm, 0.0, 1.0));
    hsv.x      = fract(hsv.x + degrees / 360.0);
    return hsv2rgb(hsv) * peak;
}

// ---- Tonal Balance (Shadows / Highlights separation) ----
// Soft luminance-based masks drive additive offsets. No clamping so HDR
// headroom is preserved for downstream tonemapping.
vec3 apply_tone_balance(vec3 c, float shadows, float highlights)
{
    float lum         = working_luma(c);
    float shadow_mask = 1.0 - smoothstep(0.0, 0.6, lum);
    float hl_mask     = smoothstep(0.4, 1.0, lum);
    c += vec3(shadows    * 0.5 * shadow_mask);
    c += vec3(highlights * 0.5 * hl_mask);
    return c;
}

// ---- Split Toning ----
// Luminance-based tint: additive colour offsets for shadows and highlights,
// with a crossover controlled by bal.
vec3 apply_split_tone(vec3 c, vec3 shad_col, vec3 hi_col, float bal)
{
    float lum     = working_luma(c);
    float shad_mk = 1.0 - smoothstep(bal - 0.3, bal + 0.3, lum);
    float hi_mk   = smoothstep(bal - 0.3, bal + 0.3, lum);
    c += shad_col * shad_mk;
    c += hi_col   * hi_mk;
    return c;
}

// ---- ASC CDL (Slope/Offset/Power) ----
// Industry-standard primary grade: out = pow(max(in * slope + offset, 0), power),
// followed by a saturation adjustment.
vec3 apply_cdl(vec3 c, vec3 slope, vec3 off, vec3 pwr, float sat_val)
{
    c = pow(max(c * slope + off, vec3(0.0)), pwr);
    float lum = working_luma(c);
    c = mix(vec3(lum), c, sat_val);
    return c;
}

vec3 apply_grading(vec3 c)
{
    if ((flags & cdl_mask) != 0u)
        c = apply_cdl(c, rgb3(cdl_slope), rgb3(cdl_offset), rgb3(cdl_power), cdl_saturation);
    if ((flags & white_balance_mask) != 0u)
        c = apply_white_balance(c, wb_temperature, wb_tint);
    if ((flags & lift_midtone_gain_mask) != 0u)
        c = apply_lmg(c, rgb3(lmg_lift), rgb3(lmg_midtone), rgb3(lmg_gain));
    if ((flags & hue_shift_mask) != 0u)
        c = apply_hue_shift(c, hue_shift_degrees);
    if ((flags & tone_balance_mask) != 0u)
        c = apply_tone_balance(c, tb_shadows, tb_highlights);
    if ((flags & split_tone_mask) != 0u)
        c = apply_split_tone(c, rgb3(split_shadow_color), rgb3(split_highlight_color), split_balance);
    return c;
}
#endif

void main()
{
    bool is_straight_alpha = (flags & is_straight_alpha_mask) == is_straight_alpha_mask;
    bool has_local_key = (flags & has_local_key_mask) == has_local_key_mask;
    bool has_layer_key  = (flags & has_layer_key_mask) == has_layer_key_mask;
    bool invert = (flags & invert_mask) == invert_mask;
    bool levels = (flags & levels_mask) == levels_mask;
    bool csb = (flags & csb_mask) == csb_mask;
    bool chroma = (flags & chroma_mask) == chroma_mask;
    bool chroma_show_mask = (flags & chroma_show_mask_mask) == chroma_show_mask_mask;

    vec4 color = get_rgba_color();
    if (is_straight_alpha)
        color.rgb *= color.a;
    if (chroma)
        color = ChromaOnCustomColor(color, chroma_show_mask);
#ifndef CASPAR_NO_GRADING
    color.rgb = apply_grading(color.rgb);
#endif
    if(levels)
        color.rgb = LevelsControl(color.rgb, min_input, gamma, max_input, min_output, max_output);
    if(csb)
        color.rgb = ContrastSaturationBrightness(color, brt, sat, con);
    // A key is the key layer's red channel. The OpenGL mixer draws it into a one-channel texture, which
    // keeps red; here the key is a whole attachment, and attachments hold colour in BGRA order (see
    // fragColor below), so red is in .b. Reading .r keyed by blue.
    if(has_local_key)
        color *= texture(textures[LOCAL_KEY], TexCoord2.st).b;
    if(has_layer_key)
        color *= texture(textures[LAYER_KEY], TexCoord2.st).b;
    color *= opacity;
    if (invert)
        color = 1.0 - color;
    if (blend_mode >= 0)
        color = blend(color);

    // attachments store color in bgra format to match opengl accelerator
    fragColor = color.bgra;
}
