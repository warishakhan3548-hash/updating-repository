Shader "Aaris/Procedural Foliage"
{
    Properties
    {
        _BaseMap("Foliage Albedo", 2D) = "white" {}
        _BaseColor("Tint", Color) = (1,1,1,1)
        _BumpMap("Normal Detail", 2D) = "bump" {}
        _BumpScale("Normal Strength", Range(0,2)) = 1
        _WindStrength("Wind Displacement (m)", Range(0,0.3)) = 0.12
        _WindSpeed("Wind Speed", Range(0,3)) = 0.9
    }

    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Packing.hlsl"

    CBUFFER_START(UnityPerMaterial)
        float4 _BaseMap_ST;
        half4 _BaseColor;
        half _BumpScale;
        float _WindStrength;
        float _WindSpeed;
    CBUFFER_END

    TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
    TEXTURE2D(_BumpMap); SAMPLER(sampler_BumpMap);

    // Visual-only motion: no scripts, allocations, network replication or moving colliders.
    // Object origin phases neighbouring trees differently, including all three LODs.
    float3 WindWorldPosition(float3 positionOS)
    {
        float3 positionWS = TransformObjectToWorld(positionOS);
        float3 originWS = TransformObjectToWorld(float3(0, 0, 0));
        float phase = dot(originWS.xz, float2(0.078, 0.107));
        float flex = saturate(positionOS.y * 0.14);
        float wave = sin(_Time.y * _WindSpeed + phase)
                   + 0.23 * sin(_Time.y * (_WindSpeed * 2.23) + phase * 1.53);
        float gust = 0.85 + 0.15 * sin(_Time.y * 0.31 + phase * 0.39);
        positionWS.xz += float2(0.86, 0.50) * (_WindStrength * flex * wave * gust);
        return positionWS;
    }
    ENDHLSL

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" }

        Pass
        {
            Name "FoliageForward"
            Tags { "LightMode"="UniversalForward" }
            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex ForwardVertex
            #pragma fragment ForwardFragment
            #pragma multi_compile_instancing
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                half3 normalWS : TEXCOORD1;
                half4 tangentWS : TEXCOORD2;
                float2 uv : TEXCOORD3;
                half fog : TEXCOORD4;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            Varyings ForwardVertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                output.positionWS = WindWorldPosition(input.positionOS.xyz);
                output.positionCS = TransformWorldToHClip(output.positionWS);
                VertexNormalInputs normal = GetVertexNormalInputs(input.normalOS, input.tangentOS);
                output.normalWS = normal.normalWS;
                output.tangentWS = half4(normal.tangentWS, input.tangentOS.w * GetOddNegativeScale());
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.fog = ComputeFogFactor(output.positionCS.z);
                return output;
            }
            half4 ForwardFragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                half3 n = normalize(input.normalWS);
                half3 t = normalize(input.tangentWS.xyz);
                half3 b = cross(n, t) * input.tangentWS.w;
                half3 detail = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);
                n = normalize(t * detail.x + b * detail.y + n * detail.z);
                Light sun = GetMainLight(TransformWorldToShadowCoord(input.positionWS));
                half3 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).rgb * _BaseColor.rgb;
                half3 lighting = SampleSH(n) + sun.color * saturate(dot(n, sun.direction))
                               * sun.shadowAttenuation * sun.distanceAttenuation;
                return half4(MixFog(albedo * lighting, input.fog), 1);
            }
            ENDHLSL
        }

        // Shadow and depth use identical displacement, avoiding a static-shadow mismatch.
        Pass
        {
            Name "FoliageShadowCaster"
            Tags { "LightMode"="ShadowCaster" }
            ZWrite On
            ZTest LEqual
            ColorMask 0
            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex ShadowVertex
            #pragma fragment ShadowFragment
            #pragma multi_compile_instancing
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            float3 _LightDirection;
            float3 _LightPosition;
            struct ShadowAttributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct ShadowVaryings { float4 positionCS : SV_POSITION; };
            ShadowVaryings ShadowVertex(ShadowAttributes input)
            {
                UNITY_SETUP_INSTANCE_ID(input);
                float3 positionWS = WindWorldPosition(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);
                #if defined(_CASTING_PUNCTUAL_LIGHT_SHADOW)
                    float3 lightDir = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDir = _LightDirection;
                #endif
                ShadowVaryings output;
                output.positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDir));
                #if UNITY_REVERSED_Z
                    output.positionCS.z = min(output.positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    output.positionCS.z = max(output.positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif
                return output;
            }
            half4 ShadowFragment(ShadowVaryings input) : SV_Target { return 0; }
            ENDHLSL
        }

        Pass
        {
            Name "FoliageDepth"
            Tags { "LightMode"="DepthOnly" }
            ZWrite On
            ColorMask 0
            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex DepthVertex
            #pragma fragment DepthFragment
            #pragma multi_compile_instancing
            struct DepthAttributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct DepthVaryings { float4 positionCS : SV_POSITION; };
            DepthVaryings DepthVertex(DepthAttributes input)
            {
                UNITY_SETUP_INSTANCE_ID(input);
                DepthVaryings output;
                output.positionCS = TransformWorldToHClip(WindWorldPosition(input.positionOS.xyz));
                return output;
            }
            half4 DepthFragment(DepthVaryings input) : SV_Target { return 0; }
            ENDHLSL
        }
    }
    FallBack Off
}
