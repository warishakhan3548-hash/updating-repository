Shader "Aaris/Wind Foliage"
{
    Properties
    {
        _BaseMap("Foliage Albedo", 2D) = "white" {}
        _BaseColor("Tint", Color) = (1,1,1,1)
        _BumpMap("Normal Detail", 2D) = "bump" {}
        _BumpScale("Normal Strength", Range(0,2)) = 1
        _WindStrength("Wind Displacement (metres)", Range(0,0.75)) = 0.24
        _WindSpeed("Wind Speed", Range(0,4)) = 1.2
        _WindHeight("Canopy Height (metres)", Float) = 12
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            half4 _BaseColor;
            half _BumpScale;
            float _WindStrength;
            float _WindSpeed;
            float _WindHeight;
        CBUFFER_END
        TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
        TEXTURE2D(_BumpMap); SAMPLER(sampler_BumpMap);

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS : NORMAL;
            float4 tangentOS : TANGENT;
            float2 uv : TEXCOORD0;
            half4 color : COLOR;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };
        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float3 positionWS : TEXCOORD0;
            half3 normalWS : TEXCOORD1;
            half4 tangentWS : TEXCOORD2;
            float2 uv : TEXCOORD3;
            half4 color : COLOR;
            half fog : TEXCOORD4;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        // World-space phase desynchronizes trees without per-instance CPU updates.
        // Only foliage meshes use this shader; rigid trunks and collision stay untouched.
        float3 WindPositionOS(float3 localPosition)
        {
            if (_WindStrength <= 0.0001) return localPosition;
            float height = saturate(localPosition.y / max(_WindHeight, 0.01));
            float flexible = smoothstep(0.16, 0.82, height);
            float3 worldPosition = TransformObjectToWorld(localPosition);
            float phase = worldPosition.x * 0.093 + worldPosition.z * 0.071 + _Time.y * _WindSpeed;
            float sway = sin(phase) * 0.7 + sin(phase * 1.73 + worldPosition.z * 0.047) * 0.3;
            worldPosition.xz += float2(0.8, 0.6) * (_WindStrength * flexible * flexible * sway);
            return TransformWorldToObject(worldPosition);
        }

        Varyings FoliageVert(Attributes input)
        {
            Varyings output = (Varyings)0;
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_TRANSFER_INSTANCE_ID(input, output);
            VertexPositionInputs position = GetVertexPositionInputs(WindPositionOS(input.positionOS.xyz));
            VertexNormalInputs normals = GetVertexNormalInputs(input.normalOS, input.tangentOS);
            output.positionCS = position.positionCS;
            output.positionWS = position.positionWS;
            output.normalWS = normals.normalWS;
            output.tangentWS = half4(normals.tangentWS, input.tangentOS.w * GetOddNegativeScale());
            output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
            output.color = input.color;
            output.fog = ComputeFogFactor(position.positionCS.z);
            return output;
        }
        half4 FoliageFrag(Varyings input) : SV_Target
        {
            UNITY_SETUP_INSTANCE_ID(input);
            half3 n = normalize(input.normalWS);
            half3 t = normalize(input.tangentWS.xyz);
            half3 b = cross(n, t) * input.tangentWS.w;
            half3 detail = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);
            n = normalize(t * detail.x + b * detail.y + n * detail.z);
            Light sun = GetMainLight(TransformWorldToShadowCoord(input.positionWS));
            half3 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).rgb * input.color.rgb * _BaseColor.rgb;
            half3 color = albedo * (SampleSH(n) + sun.color * saturate(dot(n, sun.direction)) * sun.shadowAttenuation * sun.distanceAttenuation);
            return half4(MixFog(color, input.fog), 1);
        }

        float4 FoliageDepthVert(Attributes input) : SV_POSITION
        {
            UNITY_SETUP_INSTANCE_ID(input);
            return TransformObjectToHClip(WindPositionOS(input.positionOS.xyz));
        }
        half4 FoliageDepthFrag() : SV_Target { return 0; }

        // Shadows and depth use the same animated coordinates as the forward pass.
        float3 _LightDirection;
        float4 FoliageShadowVert(Attributes input) : SV_POSITION
        {
            UNITY_SETUP_INSTANCE_ID(input);
            float3 deformed = WindPositionOS(input.positionOS.xyz);
            VertexPositionInputs position = GetVertexPositionInputs(deformed);
            VertexNormalInputs normal = GetVertexNormalInputs(input.normalOS);
            float4 result = TransformWorldToHClip(ApplyShadowBias(position.positionWS, normal.normalWS, _LightDirection));
            #if UNITY_REVERSED_Z
                result.z = min(result.z, result.w * UNITY_NEAR_CLIP_VALUE);
            #else
                result.z = max(result.z, result.w * UNITY_NEAR_CLIP_VALUE);
            #endif
            return result;
        }
        ENDHLSL

        Pass
        {
            Name "FoliageForward"
            Tags { "LightMode"="UniversalForward" }
            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex FoliageVert
            #pragma fragment FoliageFrag
            #pragma multi_compile_instancing
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog
            ENDHLSL
        }
        Pass
        {
            Name "FoliageShadowCaster"
            Tags { "LightMode"="ShadowCaster" }
            ZWrite On
            ZTest LEqual
            ColorMask 0
            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex FoliageShadowVert
            #pragma fragment FoliageDepthFrag
            #pragma multi_compile_instancing
            ENDHLSL
        }
        Pass
        {
            Name "FoliageDepthOnly"
            Tags { "LightMode"="DepthOnly" }
            ZWrite On
            ColorMask 0
            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex FoliageDepthVert
            #pragma fragment FoliageDepthFrag
            #pragma multi_compile_instancing
            ENDHLSL
        }
    }
    FallBack Off
}
