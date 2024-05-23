--liquibase formatted sql

--changeset Nicolas Griesdorn ed405296 stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-06-01
				:
	Description	: SP used in CRM to report on Activations by Brand
				:
	NG20230726	: Added PAK Activation Type (byop/branded/handset) to report
	NG20230801	: Added Simple Mobile brand to report
	NG20230815  : Refactored report to include All Brands into one select, Xfinity is seperate as it pulls different data types
	NG20240118  : TBV FWA Refactor
	NG20240124  : Added more options to ONu.UserIPAddress and changed the Start and EndDates over to IIF options
	NG20240314  : Added MobileX as Carrier option
============================================= */
ALTER PROCEDURE [Report].[P_Report_Activations_By_Brand]
    (
        @SessionID INT
        , @Carrier INT  --Simple 4 TBV Non-FWA 292, TBV FWA 404 VZW 7, Tracfone 31, GenMobile 270, Ultra Mobile 8, Cricket Wireless 56, AT&T 26, Xfinity 276, H2O Wireless 2, H2O Bolt 17, FWA 404, MobileX 302 -- noqa: LT05
        , @StartDate DATE
        , @EndDate DATE
    )
AS
BEGIN TRY
    -----------------------------------------------------------------------------------------------------------------

    IF @Carrier NOT IN (276, 404) --All Other Brands except TBV FWA And Xfinity --NG20240118
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate) --NG20240124
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate) --NG20240124

            DROP TABLE IF EXISTS #AllOtherBrand

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [OrderSKU]
                , af1.AddonTypeName
                , oia.AddonsValue
                , CASE
                    WHEN pak.Activation_Type = 'byop' THEN 'BYOP'
                    WHEN pak.Activation_Type = 'branded' THEN 'Branded'
                    WHEN pak.Activation_Type = 'handset' THEN 'Handset'
                    ELSE pak.Activation_Type
                END AS [IMEI Type]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #AllOtherBrand
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('DeviceType', 'DeviceBYOPType', 'SimType', 'SimBYOPType', 'ESimType', 'ESimNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = @Carrier
            JOIN dbo.Phone_Active_Kit AS pak ON pak.order_no = o.Order_No AND LEN(pak.Sim_ID) <= 16
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (22, 23)
                AND ISNULL(p.SubProductTypeId, 0) <> 17
                AND onu.Process = 1
                AND onu.Filled = 1
                AND onu.Void = 0
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate



            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[OrderSKU]
                , pv.[DeviceBYOPType] AS [ESN]
                , CASE WHEN ISNULL(pv.[SimBYOPType], '') = '' THEN pv.[ESimNumberType] ELSE pv.SimBYOPType END AS [SIM]
                , pv.[IMEI Type]
                , CASE WHEN pv.[ESimType] = 'on' THEN 'eSIM' ELSE 'Not eSIM' END AS [eSIM Type]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [OrderSKU]
                        , AddonsValue AS [ESN]
                        , AddonTypeName
                        , [IMEI Type]
                        , [Activation Platform]
                    FROM #AllOtherBrand
                ) AS APivotTable
            PIVOT
            (
                MAX([ESN])
                FOR AddonTypeName IN ([DeviceType], [DeviceBYOPType], [SimType], [SimBYOPType], [ESimType], [ESimNumberType])
            ) pv;


            DROP TABLE IF EXISTS #AllOtherBrand
        END;


    -----------------------------------------------------------------------------------------------------------------------

    IF @Carrier = 404 --TBV FWA (404 does not exist, it was put here as a placeholder for TBV FWA since that falls under normal TBV) --NG20230815
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate) --NG20240124
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate) --NG20240124


            DROP TABLE IF EXISTS #TBVFWA

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [OrderSKU]
                , af1.AddonTypeName
                , oia.AddonsValue
                , CASE
                    WHEN pak.Activation_Type = 'byop' THEN 'BYOP'
                    WHEN pak.Activation_Type = 'branded' THEN 'Branded'
                    WHEN pak.Activation_Type = 'handset' THEN 'Handset'
                    ELSE pak.Activation_Type
                END AS [IMEI Type]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #TBVFWA
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('DeviceType', 'DeviceBYOPType', 'SimType', 'SimBYOPType', 'ESimType', 'ESimNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = 292
            JOIN dbo.Phone_Active_Kit AS pak ON pak.order_no = o.Order_No AND LEN(pak.Sim_ID) <= 16
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (22, 23)
                AND p.SubProductTypeId = 17
                AND onu.Process = 1
                AND onu.Filled = 1
                AND onu.Void = 0
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate



            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[OrderSKU]
                , pv.[DeviceBYOPType] AS [ESN]
                , CASE WHEN ISNULL(pv.[SimBYOPType], '') = '' THEN pv.[ESimNumberType] ELSE pv.SimBYOPType END AS [SIM]
                , pv.[IMEI Type]
                , CASE WHEN pv.[ESimType] = 'on' THEN 'eSIM' ELSE 'Not eSIM' END AS [eSIM Type]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [OrderSKU]
                        , AddonsValue AS [ESN]
                        , AddonTypeName
                        , [IMEI Type]
                        , [Activation Platform]
                    FROM #TBVFWA
                ) AS APivotTable
            PIVOT
            (
                MAX([ESN])
                FOR AddonTypeName IN ([DeviceType], [DeviceBYOPType], [SimType], [SimBYOPType], [ESimType], [ESimNumberType])
            ) pv;


            DROP TABLE IF EXISTS #TBVFWA
        END;


    ---------------------------------------------------------------------------------------------------------------------------

    IF @Carrier = 276 -- Xfinity Only 276 --NG20230815
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate) --NG20240124
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate) --NG20240124

            DROP TABLE IF EXISTS #XfinityBrand

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [OrderSKU]
                , af1.AddonTypeName
                , oia.AddonsValue
                , CASE
                    WHEN pak.Activation_Type = 'byop' THEN 'BYOP'
                    WHEN pak.Activation_Type = 'branded' THEN 'Branded'
                    WHEN pak.Activation_Type = 'handset' THEN 'Handset'
                    ELSE pak.Activation_Type
                END AS [IMEI Type]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #XfinityBrand
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('DeviceType', 'DeviceBYOPType', 'SimType', 'SimBYOPType', 'ESimType', 'ESimNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = @Carrier
            JOIN dbo.Phone_Active_Kit AS pak ON pak.order_no = o.Order_No AND LEN(pak.Sim_ID) <= 16
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (22, 23)
                AND onu.Process = 1
                AND onu.Filled = 1
                AND onu.Void = 0
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate



            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[OrderSKU]
                , pv.[DeviceBYOPType] AS [MAC Address]
                , pv.[IMEI Type]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [OrderSKU]
                        , AddonsValue AS [MAC Address]
                        , AddonTypeName
                        , [IMEI Type]
                        , [Activation Platform]
                    FROM #XfinityBrand
                ) AS APivotTable
            PIVOT
            (
                MAX([MAC Address])
                FOR AddonTypeName IN ([DeviceType], [DeviceBYOPType])
            ) pv;


            DROP TABLE IF EXISTS #XfinityBrand
        END;


END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
