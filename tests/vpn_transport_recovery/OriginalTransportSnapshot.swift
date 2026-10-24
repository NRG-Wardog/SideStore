        let utun = network.isUTunAvailable
        let ipsec = network.isIKEv2IPSecAvailable
        let decision = RefreshTransportPolicy.select(
            modernOS: modernOS, mode: mode, pairing: gateway.pairingFileType,
            utun: utun, ipsec: ipsec, coreDeviceSupported: gateway.supportsCoreDeviceTransport)
