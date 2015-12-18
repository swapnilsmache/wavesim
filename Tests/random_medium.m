
% Simulates the propagation of a plane wave through a homogeneous medium
% with n=1
% Analyzes the accuracy of wavesim and PSTD (with varying time steps)

%close all;
clear all; close all;
addpath('..');

%% options for grid (gopt) and for simulation (sopt) 
PPW=4; %points per wavelength = lambda/h
sopt.lambda = 1; %in mu %lambda_0 = 1; %wavelength in vacuum (in um)
sopt.energy_threshold = 1E-25;%16;
sopt.callback_interval = 25;
sopt.max_iterations = 6000;

dt_relative_range = [0, 1./2.^(0:0.5:11.5)];

mopt.lambda = sopt.lambda;
mopt.pixel_size = sopt.lambda/PPW;
mopt.boundary_widths = [0, 0]; %per
mopt.boundary_strength = 0.2;
mopt.boundary_type = 'PML3';
N = [64*PPW 64*PPW]; % size of medium (in pixels)

%% define a plane wave source
source = sparse(N(1), N(2));
source(end/2,end/2) = 1; % plane wave source

%% simulate wave propagation for a variety of refractive indices
%reserve space for output data
relative_error = zeros(1, length(dt_relative_range));
iterations_per_wavelength = zeros(1, length(dt_relative_range));
E_PSTD = cell(1,length(dt_relative_range)-1);

%% Construct random medium
size = PPW; %size MAF window 

n0 = 1;         %background medium reffractive index
ndiff = 0.2;    %refractive index variance
k = 0.1;       %imaginary part
n_sample = ndiff*randn(N) + n0 + 1.0i*k*rand(N);

% low pass filter
n_fft = fft2(n_sample);
window = fftshift(hamming(N(1)) * hamming(N(2))');
n_sample = ifft2(n_fft.*window);

%% construct medium with desired refractive index and boundary conditions
sample = SampleMedium(n_sample, mopt);
disp(['Estimated leakage' num2str(sample.leakage^4)]);

%% wavesim simulation
sim = wavesim(sample, sopt);
iterations_per_wavelength(1) = sim.iterations_per_cycle;
[E_wavesim, state] = exec(sim, source);

%% iterate over different time steps
for t_i=2:length(dt_relative_range)
    %% create wavesim object and run the simulation
    sopt.dt_relative = dt_relative_range(t_i);
    sim = PSTD(sample, sopt);
    
    [E_PSTD{t_i-1}, state] = exec(sim, source);
end

