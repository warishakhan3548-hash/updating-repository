Shader "Aaris/Lake Water"
{
    Properties
    {
        _BaseColor("Deep Water", Color) = (0.09,0.28,0.32,1)
        _HorizonColor("Sky Reflection", Color) = (0.28,0.47,0.56,1)
        _FoamColor("Shore Highlight", Color) = (0.63,0.77,0.76,1)
        _WaveStrength("Normal Wave Strength", Range(0,0.25)) = 0.095
        _WaveFrequency("Wave Frequency", Range(0.1,2)) = 0.45
        _WaveSpeed("Wave Speed", Range(0,2)) = 0.62
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" "RenderPipeline"="UniversalPipeline" }
        Pass
        {
            Name "LakeForward"
            Tags { "LightMode"="UniversalForward" }
            Cull Back
            ZWrite On
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                half4 _HorizonColor;
                half4 _FoamColor;
                half _WaveStrength;
                half _WaveFrequency;
                half _WaveSpeed;
            CBUFFER_END

            struct Attributes
            {
                float3 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float2 uv : TEXCOORD1;
                half fog : TEXCOORD2;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings Vert(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                VertexPositionInputs vertex = GetVertexPositionInputs(input.positionOS);
                output.positionCS = vertex.positionCS;
                output.positionWS = vertex.positionWS;
                output.uv = input.uv;
                output.fog = ComputeFogFactor(vertex.positionCS.z);
                return output;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                float2 coordinate = input.positionWS.xz * _WaveFrequency;
                float seconds = _Time.y * _WaveSpeed;
                half waveA = sin(coordinate.x + seconds);
                half waveB = sin(coordinate.y * 0.81 - seconds * 0.75);
                half waveC = sin((coordinate.x + coordinate.y) * 0.61 + seconds * 0.53);
                half3 normalWS = normalize(half3(
                    -_WaveStrength * (waveA + waveC * 0.35),
                    1.0h,
                    -_WaveStrength * (waveB + waveC * 0.35)));
                half3 viewWS = SafeNormalize(GetWorldSpaceViewDir(input.positionWS));
                half fresnel = pow(1.0h - saturate(dot(normalWS, viewWS)), 4.0h);
                half shore = smoothstep(0.82h, 0.99h, length(input.uv));
                half foam = shore * (0.1h + saturate(waveA * waveB) * 0.1h);
                half3 water = lerp(_BaseColor.rgb, _HorizonColor.rgb,
                    saturate(fresnel * 0.77h + shore * 0.12h));
                water = lerp(water, _FoamColor.rgb, foam);
                Light sun = GetMainLight(TransformWorldToShadowCoord(input.positionWS));
                half3 ambient = max(SampleSH(normalWS), half3(0.12h, 0.16h, 0.18h));
                half diff = saturate(dot(normalWS, sun.direction)) *
                    sun.shadowAttenuation * sun.distanceAttenuation;
                half spec = pow(saturate(dot(reflect(-sun.direction, normalWS), viewWS)), 48.0h);
                half3 lit = water * (ambient + sun.color * diff * 0.42h) +
                    _FoamColor.rgb * sun.color * spec * diff * 0.56h;
                return half4(MixFog(lit, input.fog), 1.0h);
            }
            ENDHLSL
        }
    }
}
