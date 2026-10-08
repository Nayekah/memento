import type { Layer } from "../hooks/useBackground";

export function Backdrop({ layers, active }: { layers: [Layer, Layer]; active: 0 | 1 }) {
  return (
    <div className="stage" aria-hidden="true">
      {layers.map((layer, i) => (
        <div
          key={i}
          className={`bg${active === i && layer.src ? " on" : ""}`}
          style={layer.src ? { backgroundImage: `url("${layer.src}")`, backgroundPosition: layer.pos } : undefined}
        />
      ))}
      <div className="shade" />
      <div className="crt" />
    </div>
  );
}
