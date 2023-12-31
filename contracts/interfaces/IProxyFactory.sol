// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IProxyFactory {
    function clone(address _target) external returns(address);
}