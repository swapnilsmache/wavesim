classdef wavesim
    %Simulation of the 2-D wave equation using a Born series approach
    % Ivo M. Vellekoop 2014
    
    properties
        V;   % potential array used in simulation
        grid; %simgrid object
        roi; %position of simulation area with respect to padded array
        x_range;
        y_range;
        lambda;
        
        gpuEnabled = false; % logical to check if simulation are ran on the GPU (default: false)
        callback = @wavesim.default_callback; %callback function that is called for showing the progress of the simulation. Default shows image of the absolute value of the field.
        callback_interval = 5000; %the callback is called every 'callback_interval' steps. Default = 5
        differential_mode = false; %when set to 'true', only the differential field for each iteration is calculated: the fields are not added to get a solution to the wave equation (used for debugging)
        energy_threshold = 1E-20; %the simulation is terminated when the added energy between two iterations is lower than 'energy_threshold'. Default 1E-9
        max_iterations = 1E4; %1E4; %or when 'max_iterations' is reached. Default 10000
        it; %iteration
        time; % time comsumption
        %%internal
        k; % wave number
        epsilon;
        g0_k; % bare Green's function used in simulation
        %performance
        
        %% diagnostics and feedback
        epsilonmin; %minimum value of epsilon for which convergence is guaranteed (equal to epsilon, unless a different value for epsilon was forced)
    end
    
    methods
        function obj=wavesim(sample, options)
            %% Constructs a wave simulation object
            %	sample = SampleMedium object
            %   options.lambda = free space wavelength (same unit as pixel_size, e. g. um)
            %   options.epsilon = convergence parameter (leave empty unless forcing a specific value)
            
            fftw('planner','patient'); %optimize fft2 and ifft2 at first use
            options = wavesim.readout_input(options); %fill in default options
            
            %% Determine k_0 to minimize epsilon
            % for now, we only vary the real part of k_0 and choose its
            % imaginary part as 0. Therefore, the optimal k_0
            % follows is given by n_center (see SampleMedium)
            %% Determine epsilon
            k00 = 2*pi/options.lambda;
            obj.k = sqrt(sample.e_r_center) * k00;
            
            % First construct V without epsilon
            obj.V = sample.e_r*k00^2-obj.k^2;
            obj.epsilonmin = max(abs(obj.V(:)));
            obj.epsilonmin = max(obj.epsilonmin, 1E-3); %%minimum value to avoid divergence when simulating empty medium
            if isfield(options,'epsilon')
                obj.epsilon = options.epsilon*k00^2; %force a specific value, may not converge
            else
                obj.epsilon = obj.epsilonmin; %guaranteed convergence
            end
            
            %% Potential map (V==k^2-k_0^2-1i*epsilon)
            obj.V = obj.V - 1.0i*obj.epsilon;
            %% Calculate Green function for k_red (reduced k vector: k_red^2 = k_0^2 + 1.0i*epsilon)
            f_g0_k = @(px, py) 1./(px.^2+py.^2-(obj.k^2 + 1.0i*obj.epsilon));
            obj.g0_k = bsxfun(f_g0_k, sample.grid.px_range, sample.grid.py_range);
            
            obj.grid = sample.grid;
            obj.roi  = sample.roi;
            obj.lambda  = options.lambda;
            obj.energy_threshold = options.energy_threshold;
            obj.callback_interval = options.callback_interval;
            obj.x_range = sample.grid.x_range(obj.roi{2});
            obj.x_range = obj.x_range - obj.x_range(1);
            obj.y_range = sample.grid.y_range(obj.roi{1});
            obj.y_range = obj.y_range - obj.y_range(1);
        end
        
        function [E_x, en_all, nIter, time] = exec(obj, sources)
            tic;
            %%% Execute simulation
            %% Increase source array to grid size
            %todo: respect sparsity
            source = zeros(obj.grid.N);
            source(obj.roi{1}, obj.roi{2}) = sources;
            
            %% Check whether gpu computation option is enabled
            E_x = zeros(obj.grid.N);
            if obj.gpuEnabled
                obj.g0_k = gpuArray(obj.g0_k);
                obj.V    = gpuArray(obj.V);
                source   = gpuArray(source);
                E_x      = gpuArray(E_x);
            end
            
            %% Energy thresholds (convergence and divergence criterion)
            en_all    = zeros(1, obj.max_iterations);
            en_all(1) = wavesim.energy(source);
            threshold = obj.energy_threshold * en_all(1); %energy_threshold = fraction of total input energy
            
            %% simulation iterations
            obj.it = 1;
            while abs(en_all(obj.it)) >= threshold && obj.it <= obj.max_iterations
                obj.it = obj.it+1;
                Eold = E_x;
                E_x = single_step(obj, E_x, source);
                if (obj.differential_mode)
                    source = 0;
                end
                en_all(obj.it) = wavesim.energy(E_x(obj.roi{1}, obj.roi{2}) - Eold(obj.roi{1}, obj.roi{2}));
                %en_all(obj.it) = wavesim.energy(E_x - Eold);
                if (mod(obj.it, obj.callback_interval)==0) %now and then, call the callback function to give user feedback
                    obj.callback(obj, E_x, en_all(1:obj.it), threshold);
                end
                if abs(en_all(obj.it)) < threshold
%                if abs(en_all(obj.it))-abs(en_all(obj.it-1)) >= threshold
                    break;
                end
            end
            nIter = obj.it;
            E_x = gather(E_x(obj.roi{1}, obj.roi{2})); % converts gpu array back to normal array
            
            %% Simulation finished
            obj.time=toc;
            time = obj.time;
            if abs(en_all(obj.it)) < threshold
                disp(['Reached steady state in ' num2str(obj.it) ' iterations']);
                disp(['Time consumption: ' num2str(obj.time) ' s']);
            else
                disp('Did not reach steady state');
            end
        end
        
        function E_x = single_step(obj, E_x, source)
            % performs a single iteration of the algorithm
            E_x = E_x - (1.0i*obj.V/obj.epsilon) .* (E_x-ifft2(obj.g0_k .* fft2(obj.V.*E_x+source))); %wavesim version
        end
    end
    methods(Static)
        function options = readout_input(options)
            % function reading out all given constructor options and filling
            % in default values for missing properties
            if nargin == 0
                options = struct;
            end
            if ~isfield(options,'lambda')
                options.lambda = 1; % in um
            end
            % size of pixels
            if ~isfield(options,'pixel_size')
                options.pixel_size = 1/4*options.lambda; % in um
            end
            % stopping criterion
            if ~isfield(options,'energy_threshold')
                options.energy_threshold = 1E-20;
            end
            % callback function is called every N frames
            if ~isfield(options,'callback_interval')
                options.callback_interval = 500;
            end
        end
        
        function en = energy(E_x)
            en= sum(abs(E_x(:)).^2);
        end
        
        %default callback function. Shows real value of field, and total energy evolution
        function default_callback(obj, E, energy, threshold)
            figure(1);
            subplot(2,1,1); plot(1:length(energy),log10(energy),'b',[1,length(energy)],log10(threshold)*ones(1,2),'--r');
            title(length(energy));  xlabel('# iterations'); ylabel('log_10(energy added)');
            
            sig = log(abs(E(end/2,:)));
            subplot(2,1,2); plot(1:length(sig), sig, obj.roi{2}(1)*ones(1,2), [min(sig),max(sig)], obj.roi{2}(end)*ones(1,2), [min(sig),max(sig)]);
            title('midline cross-section')
            xlabel('y (\lambda / 4)'); ylabel('real(E_x)');
            
            %disp(['Added energy ', num2str(energy(end))]);
            drawnow;
        end
    end
end